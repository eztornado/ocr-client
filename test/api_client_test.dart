import 'package:cliente_ocr/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extrae el enum de doc_type desde el openapi.json', () {
    const spec = {
      'openapi': '3.1.0',
      'components': {
        'schemas': {
          'OCRRequest': {
            'type': 'object',
            'properties': {
              'file': {'type': 'string', 'format': 'base64'},
              'doc_type': {
                'type': 'string',
                'default': 'general',
                'enum': ['general', 'contrato', 'table'],
              },
            },
          },
        },
      },
    };
    expect(OcrApiClient.docTypesFromOpenApi(spec), ['general', 'contrato', 'table']);
  });

  test('encuentra el enum aunque esté anidado en un requestBody multipart', () {
    const spec = {
      'paths': {
        '/ocr/async/pdf': {
          'post': {
            'requestBody': {
              'content': {
                'multipart/form-data': {
                  'schema': {
                    'properties': {
                      'doc_type': {'type': 'string', 'enum': ['general', 'tarifas_15']},
                    },
                  },
                },
              },
            },
          },
        },
      },
    };
    expect(OcrApiClient.docTypesFromOpenApi(spec), ['general', 'tarifas_15']);
  });

  test('sin enum devuelve vacío (el llamante aplicará el fallback)', () {
    const spec = {
      'components': {
        'schemas': {
          'OCRRequest': {
            'properties': {
              'doc_type': {'type': 'string', 'default': 'general'},
            },
          },
        },
      },
    };
    expect(OcrApiClient.docTypesFromOpenApi(spec), isEmpty);
  });

  test('corrige mojibake en el texto del job (UTF-8 leído como Latin-1)', () {
    OcrJob job(String text) =>
        OcrJob.fromJson({'status': 'finished', 'result': {'ocr_result': text}});
    // Mojibake → recodificado a UTF-8 correcto.
    expect(job('EspaÃ±a y CafÃ©').result, 'España y Café');
    // Texto correcto: la recodificación produce U+FFFD y se queda igual.
    expect(job('España y Café').result, 'España y Café');
    // Fuera de Latin-1 no puede ser mojibake: intacto.
    expect(job('日本語 OCR').result, '日本語 OCR');
  });
}
