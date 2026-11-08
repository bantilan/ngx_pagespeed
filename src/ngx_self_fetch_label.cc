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

#include "ngx_self_fetch_label.h"

#include <arpa/inet.h>
#include <netinet/in.h>

#include <cstring>

namespace net_instaweb {
namespace {

bool IsLoopback(const struct sockaddr* address) {
  if (address == NULL) {
    return false;
  }
  if (address->sa_family == AF_INET) {
    const struct sockaddr_in* ipv4 =
        reinterpret_cast<const struct sockaddr_in*>(address);
    return (ntohl(ipv4->sin_addr.s_addr) >> 24) == 127;
  }
  if (address->sa_family == AF_INET6) {
    const struct sockaddr_in6* ipv6 =
        reinterpret_cast<const struct sockaddr_in6*>(address);
    return IN6_IS_ADDR_LOOPBACK(&ipv6->sin6_addr);
  }
  return false;
}

}  // namespace

bool NgxSelfFetchPeerIsThisServer(const struct sockaddr* peer,
                                  const struct sockaddr* local) {
  if (peer == NULL) {
    return false;
  }
  if (IsLoopback(peer)) {
    return true;
  }
  if (local == NULL || local->sa_family != peer->sa_family) {
    return false;
  }
  if (peer->sa_family == AF_INET) {
    const struct sockaddr_in* p =
        reinterpret_cast<const struct sockaddr_in*>(peer);
    const struct sockaddr_in* l =
        reinterpret_cast<const struct sockaddr_in*>(local);
    return p->sin_addr.s_addr == l->sin_addr.s_addr;
  }
  if (peer->sa_family == AF_INET6) {
    const struct sockaddr_in6* p =
        reinterpret_cast<const struct sockaddr_in6*>(peer);
    const struct sockaddr_in6* l =
        reinterpret_cast<const struct sockaddr_in6*>(local);
    return memcmp(&p->sin6_addr, &l->sin6_addr, sizeof(p->sin6_addr)) == 0;
  }
  return false;
}

void NgxInitSelfFetchLabel(NgxSelfFetchLabel* label) {
  memset(label, 0, sizeof(*label));
  label->addr.sin_family = AF_INET;
  label->addr.sin_addr.s_addr = htonl(0xe0000000u);  // 224.0.0.0
  static const char kLabelText[] = "224.0.0.0";
  static_assert(sizeof(label->text) == sizeof(kLabelText),
                "label text buffer matches the address");
  memcpy(label->text, kLabelText, sizeof(label->text));
}

}  // namespace net_instaweb
