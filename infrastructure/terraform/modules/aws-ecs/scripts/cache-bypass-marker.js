var bypassHeaders = __BYPASS_HEADERS__;
var markerCookie = '__MARKER_COOKIE__';

function handler(event) {
    var request = event.request;
    var bypass = bypassHeaders.some(function (name) { return request.headers[name] !== undefined; });
    if (bypass) {
        request.cookies[markerCookie] = {value: event.context.requestId};
    } else {
        delete request.cookies[markerCookie];
    }
    return request;
}
