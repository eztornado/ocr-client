import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error de la API con mensaje listo para mostrar al usuario.
class OcrApiException implements Exception {
  OcrApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Corrige mojibake: texto UTF-8 que llegó decodificado como Latin-1.
/// Si la recodificación produce U+FFFD, la cadena no estaba corrupta y se
/// devuelve tal cual. Con caracteres fuera de Latin-1 no puede ser mojibake.
String fixMojibake(String s) {
  try {
    final fixed = utf8.decode(latin1.encode(s), allowMalformed: true);
    return fixed.contains('�') ? s : fixed;
  } on ArgumentError {
    return s;
  }
}

/// Estado de un job asíncrono (`GET /ocr/jobs/{id}`).
class OcrJob {
  OcrJob({required this.status, this.result, this.error});

  final String status; // real del servidor: queued | started | finished | failed | not_found
  final String? result;
  final String? error;

  factory OcrJob.fromJson(Map<String, dynamic> json) {
    // El servidor anida el texto: result es un objeto {"ocr_result": "..."}, no un string.
    final result = json['result'];
    final text = result is Map ? result['ocr_result']?.toString() : result?.toString();
    return OcrJob(
      status: json['status'] as String? ?? 'unknown',
      result: text == null ? null : fixMojibake(text),
      error: json['error']?.toString(),
    );
  }
}

class OcrApiClient {
  OcrApiClient({required this.baseUrl, required this.apiKey});

  /// Sin barra final, p. ej. `https://ocr.reigreengroup.com`.
  final String baseUrl;
  final String apiKey;

  /// Fallback si /openapi.json no está disponible o no trae el enum.
  static const fallbackDocTypes = <String>[
    'general', 'contrato', 'table', 'handwriting', 'scan', 'auto_detect',
    'company_3', 'company_5', 'company_6', 'company_10', 'company_15',
    'company_17', 'company_19', 'company_24', 'company_25', 'company_26',
    'company_27', 'company_28', 'company_29',
    'tarifas_15', 'tarifas_17', 'tarifas_24',
  ];

  Map<String, String> get _headers => {'X-API-Key': apiKey};

  /// Busca recursivamente el enum de `doc_type` en cualquier parte del spec.
  /// Devuelve lista vacía si no existe (el llamante aplicará el fallback).
  static List<String> docTypesFromOpenApi(Object? node) {
    if (node is Map) {
      final docType = node['doc_type'];
      if (docType is Map) {
        final enumList = docType['enum'];
        if (enumList is List && enumList.isNotEmpty) {
          return enumList.map((e) => e.toString()).toList();
        }
      }
      for (final value in node.values) {
        final found = docTypesFromOpenApi(value);
        if (found.isNotEmpty) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = docTypesFromOpenApi(value);
        if (found.isNotEmpty) return found;
      }
    }
    return const [];
  }

  /// Tipos de documento: del openapi.json del servicio, con fallback embebido.
  Future<List<String>> getDocTypes() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/openapi.json'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return fallbackDocTypes;
      final types = docTypesFromOpenApi(jsonDecode(res.body));
      return types.isNotEmpty ? types : fallbackDocTypes;
    } catch (_) {
      return fallbackDocTypes;
    }
  }

  /// `POST /ocr/async/pdf` (multipart) → job_id. Sirve para PDF e imágenes:
  /// es la única vía que funciona en producción (el /ocr síncrono responde 500).
  /// Timeout 120 s.
  Future<String> submitDoc(List<int> bytes, String filename, String docType) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/ocr/async/pdf'))
      ..headers.addAll(_headers)
      ..fields['doc_type'] = docType
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await req.send().timeout(const Duration(seconds: 120));
    final body = await res.stream.bytesToString().timeout(const Duration(seconds: 120));
    _throwForStatus(res.statusCode, body);
    // El servidor puede responder no-JSON (HTML de un proxy) o JSON que no es objeto.
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw OcrApiException('Respuesta no JSON del servidor: $body');
    }
    if (decoded is! Map<String, dynamic>) {
      throw OcrApiException('Respuesta inesperada del servidor: $body');
    }
    final jobId = decoded['job_id'];
    if (jobId is! String || jobId.isEmpty) {
      throw OcrApiException('Respuesta inesperada del servidor: $body');
    }
    return jobId;
  }

  /// `GET /ocr/jobs/{id}` (endpoint público, sin API key). Timeout 30 s.
  Future<OcrJob> getJob(String jobId) async {
    final res = await http
        .get(Uri.parse('$baseUrl/ocr/jobs/$jobId'))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 404) {
      throw OcrApiException('Job no encontrado', statusCode: 404);
    }
    _throwForStatus(res.statusCode, res.body);
    return OcrJob.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  void _throwForStatus(int statusCode, String body) {
    if (statusCode == 401) {
      throw OcrApiException('API key inválida — revísala en Ajustes', statusCode: 401);
    }
    if (statusCode == 413) {
      throw OcrApiException('Archivo demasiado grande (máx. 50 MB)', statusCode: 413);
    }
    if (statusCode != 200) {
      throw OcrApiException('Error $statusCode del servidor: $body', statusCode: statusCode);
    }
  }
}
