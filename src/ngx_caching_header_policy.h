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

//
// Which caching headers the nginx port keeps from the server's own response
// instead of the ones the module computes.  Pulled out of ngx_pagespeed.cc so
// the decision can be unit-tested without nginx.
//
// ModifyCachingHeaders off is about HTML: the operator's caching headers on a
// page stay as they are.  A .pagespeed. resource is the module's own response
// and always carries the module's caching headers (the long-lived ones when
// the hash matches, the short private ones on the fallback path), as on the
// other servers.
//

#ifndef NGX_CACHING_HEADER_POLICY_H_
#define NGX_CACHING_HEADER_POLICY_H_

namespace net_instaweb {

enum PreserveCachingHeaders {
  kPreserveAllCachingHeaders,  // Cache-Control, ETag, Last-Modified, etc
  kPreserveOnlyCacheControl,   // Only Cache-Control.
  kDontPreserveHeaders,
};

struct NgxCachingHeaderRequest {
  NgxCachingHeaderRequest()
      : modify_caching_headers(true),
        downstream_cache_integration(false),
        pagespeed_resource(false),
        admin_handler(false),
        rebeaconing_key_matches(false) {}
  // The ModifyCachingHeaders option for the request.
  bool modify_caching_headers;
  // Downstream cache integration is configured.
  bool downstream_cache_integration;
  // The request names a .pagespeed. resource.
  bool pagespeed_resource;
  // The request is for one of the module's admin-style handlers.
  bool admin_handler;
  // The request carries the configured downstream cache rebeaconing key.
  bool rebeaconing_key_matches;
};

// The caching headers of the server's response that the module keeps for a
// request it handles.
PreserveCachingHeaders NgxPreserveCachingHeadersFor(
    const NgxCachingHeaderRequest& request);

}  // namespace net_instaweb

#endif  // NGX_CACHING_HEADER_POLICY_H_
