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

#include "ngx_caching_header_policy.h"

namespace net_instaweb {

// See build_context_for_request() in mod_instaweb.cc.
PreserveCachingHeaders NgxPreserveCachingHeadersFor(
    const NgxCachingHeaderRequest& request) {
  if (request.pagespeed_resource) {
    // The module's own response: its caching headers are the ones that
    // describe it, whatever ModifyCachingHeaders says about pages.  Keeping
    // the server's instead would send it out with none at all.
    return kDontPreserveHeaders;
  }
  if (!request.modify_caching_headers) {
    return kPreserveAllCachingHeaders;
  }
  if (!request.downstream_cache_integration) {
    // Downstream cache integration is not enabled. Disable original
    // Cache-Control headers.
    return kDontPreserveHeaders;
  }
  if (request.admin_handler) {
    return kDontPreserveHeaders;
  }
  // Downstream cache integration is enabled. If a rebeaconing key has been
  // configured and there is a ShouldBeacon header with the correct key,
  // disable original Cache-Control headers so that the instrumented page is
  // served out with no-cache.
  if (request.rebeaconing_key_matches) {
    return kDontPreserveHeaders;
  }
  return kPreserveOnlyCacheControl;
}

}  // namespace net_instaweb
