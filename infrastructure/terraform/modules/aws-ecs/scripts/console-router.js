function handler(event) {
    var request = event.request;
    if (request.uri === '/console') {
        return {statusCode: 302, headers: {location: {value: '/console/'}}};
    }
    var leaf = request.uri.split('/').pop();
    if (request.uri.indexOf('/console/') === 0 && (leaf === '' || leaf.indexOf('.') === -1)) {
        request.uri = '/console/index.html';
    }
    return request;
}
