import 'dart:async';
import 'dart:io';
import 'dart:convert';

import '../auth/auth.dart';
import 'http.dart';

/// A single HTTP request.
///
/// Instances of this class travel through a [RequestController] chain to be responded to, sometimes acquiring new values
/// as they go through controllers. Each instance of this class has a standard library [HttpRequest]. You should not respond
/// directly to the [HttpRequest], as [RequestController]s take that responsibility.
class Request implements RequestOrResponse {
  /// Creates an instance of [Request], no need to do so manually.
  Request(this.innerRequest) {
    connectionInfo = innerRequest.connectionInfo;
    _body = new HTTPRequestBody(this.innerRequest);
  }

  /// The internal [HttpRequest] of this [Request].
  ///
  /// The standard library generated HTTP request object. This contains
  /// all of the request information provided by the client. Do not respond
  /// to this value directly.
  final HttpRequest innerRequest;

  /// Information about the client connection.
  HttpConnectionInfo connectionInfo;

  /// The response object of this [Request].
  ///
  /// Do not write to this value manually. [RequestController]s are responsible for
  /// using a [Response] instance to fill out this property.
  HttpResponse get response => innerRequest.response;

  /// The path and any extracted variable parameters from the URI of this request.
  ///
  /// Typically set by a [Router] instance when the request has been piped through one,
  /// this property will contain a list of each path segment, a map of matched variables,
  /// and any remaining wildcard path.
  HTTPRequestPath path;

  /// Authorization information associated with this request.
  ///
  /// When this request goes through an [Authorizer], this value will be set with
  /// permission information from the authenticator. Use this to determine client, resource owner
  /// or other properties of the authentication information in the request. This value will be
  /// null if no permission has been set.
  Authorization authorization;

  /// The request body object.
  ///
  /// This object contains the request body if one exists and behavior for decoding it according
  /// to this instance's content-type. See [HTTPRequestBody] for details on decoding the body into
  /// an object (or objects).
  ///
  /// This value is is always non-null. If there is no request body, [HTTPRequestBody.isEmpty] is true.
  HTTPRequestBody get body => _body;
  HTTPRequestBody _body;

  /// Whether or not this request is a CORS request.
  ///
  /// This is true if there is an Origin header.
  bool get isCORSRequest => innerRequest.headers.value("origin") != null;

  /// Whether or not this is a CORS preflight request.
  ///
  /// This is true if the request HTTP method is OPTIONS and the headers contains Access-Control-Request-Method.
  bool get isPreflightRequest {
    return isCORSRequest &&
        innerRequest.method == "OPTIONS" &&
        innerRequest.headers.value("access-control-request-method") != null;
  }

  /// Container for any data a [RequestController] wants to attach to this request for the purpose of being used by a later [RequestController].
  ///
  /// Use this property to attach data to a [Request] for use by later [RequestController]s.
  Map<dynamic, dynamic> attachments = {};

  /// The timestamp for when this request was received.
  DateTime receivedDate = new DateTime.now().toUtc();

  /// The timestamp for when this request was responded to.
  ///
  /// Used for logging.
  DateTime respondDate = null;

  String get _sanitizedHeaders {
    StringBuffer buf = new StringBuffer("{");

    innerRequest?.headers?.forEach((k, v) {
      buf.write("${_truncatedString(k)} : ${_truncatedString(v.join(","))}\\n");
    });
    buf.write("}");

    return buf.toString();
  }

  String _truncatedString(String originalString, {int charSize: 128}) {
    if (originalString.length <= charSize) {
      return originalString;
    }
    return originalString.substring(0, charSize) + " ... (${originalString.length - charSize} truncated bytes)";
  }

  /// Sends a [Response] to this [Request]'s client.
  ///
  /// Do not invoke this method directly.
  ///
  /// [RequestController]s invoke this method to respond to this request.
  ///
  /// Once this method has executed, the [Request] is no longer valid. All headers from [aqueductResponse] are
  /// added to the HTTP response. If [aqueductResponse] has a [Response.body], this request will attempt to encode the body data according to the
  /// Content-Type in the [aqueductResponse]'s [Response.headers].
  ///
  /// By default, 'application/json' and 'text/plain' are supported HTTP response body encoding types. If you wish to encode another
  /// format, see [Response.addEncoder].
  Future respond(Response aqueductResponse) {
    respondDate = new DateTime.now().toUtc();

    _Reference<String> compressionType = new _Reference(null);
    var body = aqueductResponse.body;
    if (body is! Stream) {
      // Note: this pre-encodes the body in memory, such that encoding fails this will throw and we can return a 500
      // because we have yet to write to the response.
      body = _responseBodyBytes(aqueductResponse, compressionType);
    }

    response.statusCode = aqueductResponse.statusCode;
    aqueductResponse.headers?.forEach((k, v) {
      response.headers.add(k, v);
    });

    if (body == null) {
      return response.close();
    }

    response.headers.add(
        HttpHeaders.CONTENT_TYPE, aqueductResponse.contentType.toString());

    if (body is List) {
      if (compressionType.value != null) {
        response.headers.add(HttpHeaders.CONTENT_ENCODING, compressionType.value);
      }
      response.headers.add(HttpHeaders.CONTENT_LENGTH, body.length);

      response.add(body);

      return response.close();
    }

    var bodyStream = _responseBodyStream(aqueductResponse, compressionType);
    if (compressionType.value != null) {
      response.headers.add(HttpHeaders.CONTENT_ENCODING, compressionType.value);
    }
    response.headers.add(HttpHeaders.TRANSFER_ENCODING, "chunked");

    return response.addStream(bodyStream).then((_) {
      return response.close();
    }).catchError((e, st) {
      throw new HTTPStreamingException(e, st);
    });
  }

  List<int> _responseBodyBytes(Response resp, _Reference<String> compressionType) {
    if (resp.body == null) {
      return null;
    }

    Codec codec;
    if (resp.encodeBody) {
      codec = HTTPCodecRepository.defaultInstance.codecForContentType(resp.contentType);
    }

    // todo(joeconwaystk): Set minimum threshold on number of bytes needed to perform gzip, do not gzip otherwise.
    // There isn't a great way of doing this that I can think of except splitting out gzip from the fused codec,
    // have to measure the value of fusing vs the cost of gzipping smaller data.
    var canGzip =
        HTTPCodecRepository.defaultInstance.isContentTypeCompressable(resp.contentType)
            && _acceptsGzipResponseBody;


    if (codec == null) {
      if (resp.body is! List<int>) {
        throw new HTTPCodecException("Invalid body '${resp.body.runtimeType}' for Content-Type '${resp.contentType}'");
      }

      if (canGzip) {
        compressionType.value = "gzip";
        return GZIP.encode(resp.body);
      }
      return resp.body;
    }

    if (canGzip) {
      compressionType.value = "gzip";
      codec = codec.fuse(GZIP);
    }

    return codec.encode(resp.body);
  }

  Stream<List<int>> _responseBodyStream(Response resp, _Reference<String> compressionType) {
    Codec codec;
    if (resp.encodeBody) {
      codec = HTTPCodecRepository.defaultInstance.codecForContentType(resp.contentType);
    }

    var canGzip =
        HTTPCodecRepository.defaultInstance.isContentTypeCompressable(resp.contentType)
            && _acceptsGzipResponseBody;
    if (codec == null) {
      if (canGzip) {
        compressionType.value = "gzip";
        return GZIP.encoder.bind(resp.body);
      }

      return resp.body;
    }

    if (canGzip) {
      compressionType.value = "gzip";
      codec = codec.fuse(GZIP);
    }

    return codec.encoder.bind(resp.body);
  }

  bool get _acceptsGzipResponseBody {
    return innerRequest
        .headers[HttpHeaders.ACCEPT_ENCODING]
        ?.any((v) => v.split(",").any((s) => s.trim() == "gzip")) ?? false;
  }

  String toString() {
    return "${innerRequest.method} ${this.innerRequest.uri} (${this.receivedDate.millisecondsSinceEpoch})";
  }

  /// A string that represents more details about the request, typically used for logging.
  String toDebugString(
      {bool includeElapsedTime: true,
      bool includeRequestIP: true,
      bool includeMethod: true,
      bool includeResource: true,
      bool includeStatusCode: true,
      bool includeContentSize: false,
      bool includeHeaders: false}) {
    var builder = new StringBuffer();
    if (includeRequestIP) {
      builder.write("${innerRequest.connectionInfo?.remoteAddress?.address} ");
    }
    if (includeMethod) {
      builder.write("${innerRequest.method} ");
    }
    if (includeResource) {
      builder.write("${innerRequest.uri} ");
    }
    if (includeElapsedTime && respondDate != null) {
      builder
          .write("${respondDate.difference(receivedDate).inMilliseconds}ms ");
    }
    if (includeStatusCode) {
      builder.write("${innerRequest.response.statusCode} ");
    }
    if (includeContentSize) {
      builder.write("${innerRequest.response.contentLength} ");
    }
    if (includeHeaders) {
      builder.write("${_sanitizedHeaders} ");
    }

    return builder.toString();
  }
}

class HTTPStreamingException implements Exception {
  HTTPStreamingException(this.underlyingException, this.trace);

  dynamic underlyingException;
  StackTrace trace;
}

class _Reference<T> {
  _Reference(this.value);
  T value;
}