/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 * 
 *   http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */



extern "C" {

#include <ngx_channel.h>

}

#include "ngx_event_connection.h"

#include <unistd.h>

#include "pagespeed/kernel/base/google_message_handler.h"
#include "pagespeed/kernel/base/message_handler.h"

namespace net_instaweb {

  NgxEventConnection::NgxEventConnection(callbackPtr callback)
    : event_handler_(callback),
      connection_(NULL),
      closed_(false) {
  pthread_mutex_init(&write_mutex_, NULL);
}

NgxEventConnection::~NgxEventConnection() {
  pthread_mutex_destroy(&write_mutex_);
}

bool NgxEventConnection::Init(ngx_cycle_t* cycle) {
  int file_descriptors[2];

  if (pipe(file_descriptors) != 0) {
    ngx_log_error(NGX_LOG_EMERG, cycle->log, 0, "pagespeed: pipe() failed");
    return false;
  }
  if (ngx_nonblocking(file_descriptors[0]) == -1) {
    ngx_log_error(NGX_LOG_EMERG, cycle->log, ngx_socket_errno,
                  ngx_nonblocking_n "pagespeed:  pipe[0] failed");
  } else if (ngx_nonblocking(file_descriptors[1]) == -1) {
    ngx_log_error(NGX_LOG_EMERG, cycle->log, ngx_socket_errno,
                  ngx_nonblocking_n "pagespeed:  pipe[1] failed");
  } else if (!CreateNgxConnection(cycle, file_descriptors[0])) {
    ngx_log_error(NGX_LOG_EMERG, cycle->log, 0,
                  "pagespeed: failed to create connection.");
  } else {
    pipe_read_fd_ = file_descriptors[0];
    pipe_write_fd_ = file_descriptors[1];
    // Attempt to bump the pipe capacity, because running out of buffer space
    // can potentially lead up to writes spinning on EAGAIN.
    // See https://github.com/apache/incubator-pagespeed-ngx/issues/1380
    // TODO(oschaaf): Consider implementing a queueing mechanism for retrying
    // failed writes.
#ifdef F_SETPIPE_SZ
    fcntl(pipe_write_fd_, F_SETPIPE_SZ, 200*1024 /* minimal amount of bytes */);
#endif
    return true;
  }
  close(file_descriptors[0]);
  close(file_descriptors[1]);
  return false;
}

bool NgxEventConnection::CreateNgxConnection(ngx_cycle_t* cycle,
                                             ngx_fd_t pipe_fd) {
  // A copy of nginx's ngx_add_channel_event(), which does not hand the
  // ngx_connection_t it creates back to its caller: Shutdown() needs that
  // connection to close the read side through nginx.
  // pipe_fd (the read side of the pipe will end up as c->fd on the
  // underlying ngx_connection_t that gets created here)
  ngx_connection_t* c = ngx_get_connection(pipe_fd, cycle->log);
  if (c == NULL) {
    return false;
  }
  c->pool = cycle->pool;
  ngx_event_t* rev = c->read;
  ngx_event_t* wev = c->write;
  rev->log = cycle->log;
  wev->log = cycle->log;
  rev->channel = 1;
  wev->channel = 1;
  rev->handler = &NgxEventConnection::ReadEventHandler;

  ngx_int_t rc;
  if (ngx_add_conn && (ngx_event_flags & NGX_USE_EPOLL_EVENT) == 0) {
    rc = ngx_add_conn(c);
  } else {
    rc = ngx_add_event(rev, NGX_READ_EVENT, 0);
  }
  if (rc != NGX_OK) {
    ngx_free_connection(c);
    return false;
  }
  connection_ = c;
  return true;
}

void NgxEventConnection::ReadEventHandler(ngx_event_t* ev) {
  ngx_connection_t* c = static_cast<ngx_connection_t*>(ev->data);
  ngx_int_t result = ngx_handle_read_event(ev, 0);
  if (result != NGX_OK) {
    CHECK(false) << "pagespeed: ngx_handle_read_event error: " << result;
  }

  if (ev->timedout) {
    ev->timedout = 0;
    return;
  }

  // On a read error (EOF or a real error) leave the close to Shutdown():
  // this static handler cannot reach the owning object to null connection_,
  // so closing here would let Shutdown() close the same connection object a
  // second time, after nginx recycled it into an unrelated connection. The
  // write end is only ever closed by Shutdown(), on this same event-loop
  // thread, which closes the read side immediately after, so in practice
  // nothing reaches this path before Shutdown() owns the teardown.
  (void)NgxEventConnection::ReadAndNotify(c->fd);
}

// Deserialize ps_event_data's from the pipe as they become available.
// Subsequently do some bookkeeping, cleanup, and error checking to keep
// the mess out of ps_base_fetch_handler.
bool NgxEventConnection::ReadAndNotify(ngx_fd_t fd) {
  while (true) {
    // We read only one ps_event_data at a time for now:
    // We can end up recursing all the way and end up calling ourselves here.
    // If that happens in the middle of looping over multiple ps_event_data's we
    // have obtained with read(), the results from the next read() will make us
    // process events out of order. Which can give headaches.
    // Alternatively, we could maintain a queue to make sure we process in
    // sequence
    ps_event_data data;
    ngx_int_t size = read(fd, static_cast<void*>(&data), sizeof(data));

    if (size == -1) {
      if (errno == EINTR) {
        continue;
      // TODO(oschaaf): should we worry about spinning here?
      } else if (ngx_errno == EAGAIN || ngx_errno == EWOULDBLOCK) {
        return true;
      }
    }

    if (size <= 0) {
      return false;
    }

    data.connection->event_handler_(data);
    return true;
  }
}

bool NgxEventConnection::WriteEvent(void* sender) {
  return WriteEvent('X' /* Anything char is fine */, sender);
}

bool NgxEventConnection::WriteEvent(char type, void* sender) {
  ssize_t size = 0;
  ps_event_data data;

  ngx_memzero(&data, sizeof(data));
  data.type = type;
  data.sender = sender;
  data.connection = this;

  // Retry with exponential backoff to avoid CPU spin when the pipe
  // buffer is full. Starts at 100us, doubles each
  // retry, caps at ~100ms per sleep, gives up after 50 attempts
  // (~6.5 seconds total worst case).
  static const int kMaxRetries = 50;
  static const useconds_t kInitialBackoffUs = 100;
  static const useconds_t kMaxBackoffUs = 100000;  // 100ms
  int retries = 0;
  useconds_t backoff_us = kInitialBackoffUs;

  pthread_mutex_lock(&write_mutex_);
  if (closed_) {
    // Shutdown() has closed the pipe: the worker is exiting, nobody would
    // collect the output, and the fd number may already have been reused.
    // Drop the event.
    pthread_mutex_unlock(&write_mutex_);
    return false;
  }
  while (true) {
    size = write(pipe_write_fd_,
                 static_cast<void*>(&data), sizeof(data));
    if (size == sizeof(data)) {
      pthread_mutex_unlock(&write_mutex_);
      return true;
    } else if (size == -1) {
      if (ngx_errno == EINTR) {
        continue;  // EINTR: retry immediately, no backoff needed.
      }
      if (ngx_errno == EAGAIN || ngx_errno == EWOULDBLOCK) {
        if (++retries > kMaxRetries) {
          pthread_mutex_unlock(&write_mutex_);
          return false;  // Pipe remains full after sustained backoff.
        }
        // Back off without holding the mutex, so Shutdown() is not
        // starved by a writer spinning on a full pipe.
        pthread_mutex_unlock(&write_mutex_);
        usleep(backoff_us);
        pthread_mutex_lock(&write_mutex_);
        if (closed_) {
          pthread_mutex_unlock(&write_mutex_);
          return false;
        }
        if (backoff_us < kMaxBackoffUs) {
          backoff_us *= 2;
        }
        continue;
      }
      pthread_mutex_unlock(&write_mutex_);
      return false;
    } else {
      CHECK(false) << "pagespeed: unexpected return value from write(): "
                   << size;
    }
  }
  CHECK(false) << "Should not get here";
  return false;
}

// Reads and processes what is available in the pipe.
void NgxEventConnection::Drain() {
  NgxEventConnection::ReadAndNotify(pipe_read_fd_);
}

void NgxEventConnection::Shutdown() {
  // Mark the connection closed and close the write side under write_mutex_,
  // so a writer either finishes its write before the close or sees closed_
  // and drops the event. Without this, a rewrite thread that outlived the
  // shutdown drain could write to the closed fd number after worker-exit
  // teardown (factory shutdown, record pool shutdown, cache cleanup) reused
  // it for a new file or socket.
  pthread_mutex_lock(&write_mutex_);
  closed_ = true;
  close(pipe_write_fd_);
  pthread_mutex_unlock(&write_mutex_);
  // Close the read side through nginx: it is a channel connection registered
  // with the event loop, and a raw close() would leave the loop's event
  // bookkeeping pointing at a dead fd.
  if (connection_ != NULL) {
    ngx_close_connection(connection_);
    connection_ = NULL;
  } else {
    close(pipe_read_fd_);
  }
}

}  // namespace net_instaweb
