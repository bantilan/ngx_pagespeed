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

#ifndef NGX_PAGESPEED_SRC_NGX_SELF_FETCH_LABEL_H_
#define NGX_PAGESPEED_SRC_NGX_SELF_FETCH_LABEL_H_

#include <netinet/in.h>
#include <sys/socket.h>

#include <cstddef>

namespace net_instaweb {

// A recognized request to this server must not receive localhost's access-rule
// privileges, regardless of which client caused the fetch.
struct NgxSelfFetchLabel {
  struct sockaddr_in addr;
  unsigned char text[sizeof("224.0.0.0")];
};

template <class Connection>
struct NgxSelfFetchSaved {
  Connection* connection;
  struct sockaddr* sockaddr;
  socklen_t socklen;
  size_t addr_text_len;
  unsigned char* addr_text_data;
};

bool NgxSelfFetchPeerIsThisServer(const struct sockaddr* peer,
                                  const struct sockaddr* local);
void NgxInitSelfFetchLabel(NgxSelfFetchLabel* label);

template <class Connection>
void NgxRelabelSelfFetch(Connection* connection, NgxSelfFetchLabel* label,
                         NgxSelfFetchSaved<Connection>* saved) {
  saved->connection = connection;
  saved->sockaddr = connection->sockaddr;
  saved->socklen = connection->socklen;
  saved->addr_text_len = connection->addr_text.len;
  saved->addr_text_data = connection->addr_text.data;
  NgxInitSelfFetchLabel(label);
  connection->sockaddr = reinterpret_cast<struct sockaddr*>(&label->addr);
  connection->socklen = sizeof(label->addr);
  connection->addr_text.data = label->text;
  connection->addr_text.len = sizeof(label->text) - 1;
}

template <class Connection>
void NgxRestoreSelfFetch(const NgxSelfFetchSaved<Connection>& saved) {
  Connection* connection = saved.connection;
  connection->sockaddr = saved.sockaddr;
  connection->socklen = saved.socklen;
  connection->addr_text.len = saved.addr_text_len;
  connection->addr_text.data = saved.addr_text_data;
}

}  // namespace net_instaweb

#endif  // NGX_PAGESPEED_SRC_NGX_SELF_FETCH_LABEL_H_
