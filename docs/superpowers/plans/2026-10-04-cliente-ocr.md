# Cliente OCR de escritorio — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App Flutter (Linux) que consume el microservicio OCR de `https://ocr.reigreengroup.com`: API key persistente, tipos de documento dinámicos desde el OpenAPI, subida de PDF (asíncrono con polling) o imagen (síncrono), y resultado en texto copiable.

**Architecture:** Una ventana, una pantalla (`lib/main.dart`) más un cliente HTTP puro (`lib/api_client.dart`). Estado con `setState`, sin state managers. El PDF va a `POST /ocr/async/pdf` + polling de `GET /ocr/jobs/{id}` con la estrategia adaptativa de la API; la imagen va síncrona a `POST /ocr`.

**Tech Stack:** Flutter desktop (Linux), `http`, `file_picker`, `shared_preferences`.

**Spec:** `docs/superpowers/specs/2026-10-04-cliente-ocr-design.md`

## Global Constraints

- Proyecto en `~/cliente-ocr`, nombre de paquete `cliente_ocr`, solo plataforma `linux`.
- Flutter ya está en el PATH (`/home/ivan/flutter/bin/flutter`); usar `flutter` a secas.
- Dependencias permitidas: solo `http`, `file_picker`, `shared_preferences` (más el SDK). Nada de provider/riverpod/dio.
- Auth: header `X-API-Key` (NO Bearer) en todos los endpoints salvo `/openapi.json` y `/ocr/jobs/{id}`.
- Timeouts: `openapi.json` 15 s, submit PDF 120 s, `getJob` 30 s, imagen OCR 120 s.
- Polling: 2 s durante los primeros 30 s, 5 s hasta 90 s, 10 s después.
- Máx. 50 MB por archivo; extensiones `pdf, png, jpg, jpeg, bmp, tif, tiff, webp`.
- Un solo test automatizado (parseo del enum `doc_type`); sin mocks de red.
- Commits pequeños y frecuentes, mensajes convencionales (`feat:`, `test:`, `chore:`), terminados en `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

### Task 1: Scaffold Flutter Linux + dependencias

**Files:**
- Create: todo el scaffold de `flutter create` (pubspec.yaml, lib/main.dart, linux/, test/)
- Modify: `linux/my_application.cc` (título de ventana)
- Modify: `pubspec.yaml` (dependencias, vía `flutter pub add`)

**Interfaces:**
- Consumes: nada.
- Produces: proyecto Flutter que compila para Linux con paquete `cliente_ocr` y las tres dependencias instaladas.

- [ ] **Step 1: Crear el proyecto en el directorio existente (conserva `docs/` y `.git`)**

```bash
cd ~/cliente-ocr && flutter create --platforms=linux --org com.reigreen --project-name cliente_ocr .
```

Expected: «All done!» y lista de ficheros creados. No debe tocar `docs/`.

- [ ] **Step 2: Añadir las tres dependencias**

```bash
cd ~/cliente-ocr && flutter pub add http file_picker shared_preferences
```

Expected: `pubspec.yaml` con `http: ^x`, `file_picker: ^x`, `shared_preferences: ^x` y «exit code 0».

- [ ] **Step 3: Título de la ventana**

```bash
cd ~/cliente-ocr && sed -i 's/gtk_window_set_title(window, "cliente_ocr")/gtk_window_set_title(window, "Cliente OCR")/' linux/my_application.cc && grep -n 'set_title' linux/my_application.cc
```

Expected: la línea con `gtk_window_set_title(window, "Cliente OCR")`. Si el grep no muestra nada (formato distinto del template), abrir el fichero y editar el `set_title` a mano.

- [ ] **Step 4: Verificar que analiza limpio**

```bash
cd ~/cliente-ocr && flutter analyze
```

Expected: `No issues found!` (puede avisar de que falta ejecutar `flutter pub get` — ejecutarlo y repetir).

- [ ] **Step 5: Compilar de humo en debug (valida toolchain GTK/ninja)**

```bash
cd ~/cliente-ocr && flutter build linux --debug
```

Expected: `✓ Built build/linux/x64/debug/bundle/cliente_ocr`.

- [ ] **Step 6: Commit**

```bash
cd ~/cliente-ocr && git add -A && git commit -m "chore: scaffold Flutter Linux + http, file_picker, shared_preferences

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `api_client.dart` — excepción, fallback y parseo de `doc_type` (TDD)

**Files:**
- Create: `lib/api_client.dart`
- Create: `test/api_client_test.dart`

**Interfaces:**
- Consumes: nada (primera pieza de `lib/`).
- Produces (lo que Task 3 y Task 4 usan, firmas exactas):
  - `class OcrApiException implements Exception` — constructor `OcrApiException(String message, {int? statusCode})`, `toString()` devuelve `message`.
  - `class OcrApiClient` — constructor `OcrApiClient({required String baseUrl, required String apiKey})`.
  - `static const List<String> OcrApiClient.fallbackDocTypes` — lista embebida completa.
  - `static List<String> OcrApiClient.docTypesFromOpenApi(Object? node)` — `const []` si no encuentra enum.
  - `Future<List<String>> OcrApiClient.getDocTypes()` — nunca lanza: devuelve fallback ante cualquier fallo.

- [ ] **Step 1: Reconocer dónde vive el enum en el OpenAPI real (informativo)**

```bash
curl -s https://ocr.reigreengroup.com/openapi.json | grep -o '"doc_type": *{[^}]*}' | head -5
```

Expected: objetos JSON con `doc_type`. Si entre ellos aparece `"enum": [...]`, el cliente será dinámico real; si no aparece ninguno, el fallback embebido es quien manda y hay que comprobar que sus valores coinciden con los listados en https://ocr.reigreengroup.com/docs. En ambos casos el código de esta tarea es idéntico (enum + fallback).

- [ ] **Step 2: Escribir el test que falla**

Crear `test/api_client_test.dart`:

```dart
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
}
```

- [ ] **Step 3: Ejecutar y verificar que falla**

```bash
cd ~/cliente-ocr && flutter test
```

Expected: FAIL — `Error: Couldn't resolve the package 'cliente_ocr'` o `api_client.dart` no encontrado.

- [ ] **Step 4: Implementación mínima**

Crear `lib/api_client.dart`:

```dart
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
}
```

- [ ] **Step 5: Ejecutar y verificar que pasa**

```bash
cd ~/cliente-ocr && flutter test
```

Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
cd ~/cliente-ocr && git add lib/api_client.dart test/api_client_test.dart && git commit -m "feat: parseo de doc_type desde OpenAPI con fallback embebido

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `api_client.dart` — `submitPdf`, `getJob`, `ocrImage`

**Files:**
- Modify: `lib/api_client.dart` (añadir clase `OcrJob` y tres métodos a `OcrApiClient`)

**Interfaces:**
- Consumes: `OcrApiException` (Task 2), `_headers` (Task 2).
- Produces (firmas exactas que usa Task 5):
  - `class OcrJob` — `String status`, `String? result`, `String? error`, factory `OcrJob.fromJson(Map<String, dynamic>)`.
  - `Future<String> submitPdf(List<int> bytes, String filename, String docType)` → devuelve `job_id`.
  - `Future<OcrJob> getJob(String jobId)` → estado del job.
  - `Future<String> ocrImage(List<int> bytes, String docType)` → texto OCR.

Sin test de red (decisión de spec: sin mocks). La puerta de calidad de esta tarea es `flutter analyze` + la API real en el smoke del Task 6.

- [ ] **Step 1: Añadir `OcrJob` justo encima de `OcrApiClient`**

```dart
/// Estado de un job asíncrono (`GET /ocr/jobs/{id}`).
class OcrJob {
  OcrJob({required this.status, this.result, this.error});

  final String status; // queued | processing | completed | failed
  final String? result;
  final String? error;

  factory OcrJob.fromJson(Map<String, dynamic> json) => OcrJob(
        status: json['status'] as String? ?? 'unknown',
        result: json['result']?.toString(),
        error: json['error']?.toString(),
      );
}
```

- [ ] **Step 2: Añadir los tres métodos dentro de `OcrApiClient` (tras `getDocTypes`)**

```dart
  /// `POST /ocr/async/pdf` (multipart) → job_id. Timeout 120 s.
  Future<String> submitPdf(List<int> bytes, String filename, String docType) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/ocr/async/pdf'))
      ..headers.addAll(_headers)
      ..fields['doc_type'] = docType
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await req.send().timeout(const Duration(seconds: 120));
    final body = await res.stream.bytesToString();
    _throwForStatus(res.statusCode, body);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final jobId = json['job_id'];
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

  /// `POST /ocr` síncrono para imágenes (JSON con base64). Timeout 120 s.
  Future<String> ocrImage(List<int> bytes, String docType) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/ocr'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'file': base64Encode(bytes), 'doc_type': docType}),
        )
        .timeout(const Duration(seconds: 120));
    _throwForStatus(res.statusCode, res.body);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['ocr_result']?.toString() ?? '';
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
```

- [ ] **Step 3: Verificar analyze y tests**

```bash
cd ~/cliente-ocr && flutter analyze && flutter test
```

Expected: `No issues found!` + `All tests passed!` (los tests siguen pasando: nada de lo existente cambió).

- [ ] **Step 4: Commit**

```bash
cd ~/cliente-ocr && git add lib/api_client.dart && git commit -m "feat: submitPdf asíncrono, polling de jobs y OCR síncrono de imágenes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `main.dart` — pantalla única, ajustes persistentes y dropdown

**Files:**
- Modify: `lib/main.dart` (reemplaza el contador de `flutter create` por completo)

**Interfaces:**
- Consumes: `OcrApiClient.fallbackDocTypes`, `getDocTypes()` (Task 2).
- Produces (que Task 5 reemplaza/reusa): método stub `Future<void> _pickAndProcess()`; método `void _cancel()` (sin flag de cancelación todavía); layout completo con fila de estado, panel de resultado y botón Copiar ya cableados.

- [ ] **Step 1: Reemplazar `lib/main.dart` entero por:**

```dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

void main() => runApp(const ClienteOcrApp());

class ClienteOcrApp extends StatelessWidget {
  const ClienteOcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cliente OCR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const HomePage(),
    );
  }
}

enum _Phase { idle, working, done }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _defaultUrl = 'https://ocr.reigreengroup.com';
  static const _maxBytes = 50 * 1024 * 1024;
  static const _allowedExtensions = ['pdf', 'png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'webp'];

  String _baseUrl = _defaultUrl;
  String _apiKey = '';
  List<String> _docTypes = OcrApiClient.fallbackDocTypes;
  String _docType = 'general';

  PlatformFile? _file;
  _Phase _phase = _Phase.idle;
  String _statusText = '';
  String _result = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cliente OCR'),
        actions: [
          IconButton(icon: const Icon(Icons.settings), tooltip: 'Ajustes', onPressed: _openSettings),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _docType,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de documento',
                      border: OutlineInputBorder(),
                    ),
                    items: [for (final t in _docTypes) DropdownMenuItem(value: t, child: Text(t))],
                    onChanged: busy ? null : (v) => setState(() => _docType = v!),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: busy ? null : _pickAndProcess,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Adjuntar'),
                ),
              ],
            ),
            if (_file != null) ...[
              const SizedBox(height: 12),
              Text(
                '${_file!.name} · ${(_file!.size / 1024 / 1024).toStringAsFixed(1)} MB',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_statusText)),
                  TextButton(onPressed: _cancel, child: const Text('Cancelar')),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _result.isEmpty
                    ? Center(
                        child: Text('El resultado OCR aparecerá aquí',
                            style: Theme.of(context).textTheme.bodySmall))
                    : SingleChildScrollView(
                        child: SelectableText(_result,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                      ),
              ),
            ),
            if (_phase == _Phase.done && _result.isNotEmpty) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _copyResult,
                icon: const Icon(Icons.copy),
                label: const Text('Copiar'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _baseUrl = prefs.getString('base_url') ?? _defaultUrl;
      _apiKey = prefs.getString('api_key') ?? '';
    });
    if (_apiKey.isEmpty) {
      await _openSettings(firstRun: true);
    } else {
      await _loadDocTypes();
    }
  }

  Future<void> _openSettings({bool firstRun = false}) async {
    final urlCtrl = TextEditingController(text: _baseUrl);
    final keyCtrl = TextEditingController(text: _apiKey);
    try {
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: !firstRun,
        builder: (context) => AlertDialog(
          title: const Text('Ajustes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                decoration:
                    const InputDecoration(labelText: 'URL base', hintText: _defaultUrl),
              ),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: 'API key (cabecera X-API-Key)'),
              ),
            ],
          ),
          actions: [
            if (!firstRun)
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true), child: const Text('Guardar')),
          ],
        ),
      );
      if (saved != true) return;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _baseUrl = urlCtrl.text.trim().replaceAll(RegExp(r'/+$'), '');
        _apiKey = keyCtrl.text.trim();
      });
      await prefs.setString('base_url', _baseUrl);
      await prefs.setString('api_key', _apiKey);
      await _loadDocTypes();
    } finally {
      urlCtrl.dispose();
      keyCtrl.dispose();
    }
  }

  Future<void> _loadDocTypes() async {
    if (_apiKey.isEmpty) return;
    final types = await OcrApiClient(baseUrl: _baseUrl, apiKey: _apiKey).getDocTypes();
    if (!mounted) return;
    setState(() {
      _docTypes = types;
      if (!types.contains(_docType)) _docType = types.first;
    });
  }

  // ponytail: stub, Task 5 lo reemplaza por el flujo real
  Future<void> _pickAndProcess() async {
    _showSnack('Procesamiento de archivos: pendiente de la siguiente tarea');
  }

  void _cancel() => setState(() {
        _phase = _Phase.idle;
        _statusText = '';
      });

  Future<void> _copyResult() async {
    await Clipboard.setData(ClipboardData(text: _result));
    _showSnack('Copiado al portapapeles');
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}
```

- [ ] **Step 2: Analizar y arrancar**

```bash
cd ~/cliente-ocr && flutter analyze && flutter run -d linux
```

Expected: `No issues found!`; la app abre y el diálogo de Ajustes aparece automáticamente (primera ejecución, sin key guardada).

- [ ] **Step 3: Smoke de esta tarea (a mano, cerrando la app al terminar)**

1. En Ajustes: dejar la URL por defecto, escribir una API key de prueba (`test`), Guardar.
2. Cerrar y relanzar `flutter run -d linux`: el diálogo NO aparece (la key está persistida).
3. Ajustes → icono de engranaje: se abre con los valores guardados.
4. El dropdown muestra tipos (si la key `test` no es válida igual carga `openapi.json`… es público; si no, lista de fallback).
5. Botón Adjuntar → SnackBar del stub.

Expected: todo lo anterior funciona. Borrar la key de prueba antes de seguir no hace falta (se sobrescribe).

- [ ] **Step 4: Commit**

```bash
cd ~/cliente-ocr && git add lib/main.dart && git commit -m "feat: pantalla única con ajustes persistentes y tipos de documento dinámicos

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `main.dart` — flujo asíncrono (adjuntar → polling → resultado)

**Files:**
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `submitPdf`, `getJob`, `ocrImage`, `OcrApiException` (Task 3); stub `_pickAndProcess`, `_cancel`, layout del Task 4.
- Produces: la app completa y funcional.

- [ ] **Step 1: Añadir el campo `_cancelled` junto a los demás (tras `String? _error;`)**

```dart
  bool _cancelled = false;
```

- [ ] **Step 2: Reemplazar el stub `_pickAndProcess` y reescribir `_cancel` por:**

```dart
  Future<void> _pickAndProcess() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    if (file.size > _maxBytes) {
      _showSnack('Archivo demasiado grande (máx. 50 MB)', error: true);
      return;
    }
    setState(() {
      _file = file;
      _phase = _Phase.working;
      _result = '';
      _error = null;
      _statusText = 'Enviando…';
      _cancelled = false;
    });
    try {
      final client = OcrApiClient(baseUrl: _baseUrl, apiKey: _apiKey);
      if ((file.extension ?? '').toLowerCase() == 'pdf') {
        await _processPdf(client, file);
      } else {
        final text = await client.ocrImage(file.bytes!, _docType);
        if (!mounted) return;
        setState(() {
          _result = text;
          _phase = _Phase.done;
          _statusText = '';
        });
      }
    } catch (e) {
      if (_cancelled || !mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _statusText = '';
        _error = e.toString();
      });
      _showSnack(e.toString(), error: true);
    }
  }

  /// PDF → submit asíncrono + polling con la estrategia adaptativa de la API.
  Future<void> _processPdf(OcrApiClient client, PlatformFile file) async {
    final jobId = await client.submitPdf(file.bytes!, file.name, _docType);
    if (!mounted) return;
    setState(() => _statusText = 'En cola…');
    final start = DateTime.now();
    while (true) {
      await Future.delayed(_pollDelay(DateTime.now().difference(start)));
      if (_cancelled || !mounted) return;
      final job = await client.getJob(jobId);
      if (_cancelled || !mounted) return;
      if (job.status == 'completed') {
        setState(() {
          _result = job.result ?? '';
          _phase = _Phase.done;
          _statusText = '';
        });
        return;
      }
      if (job.status == 'failed') {
        throw OcrApiException(job.error ?? 'El procesamiento del documento falló');
      }
      setState(() =>
          _statusText = '${job.status} · ${DateTime.now().difference(start).inSeconds} s');
    }
  }

  /// 2 s durante los primeros 30 s, 5 s hasta 90 s, 10 s después (spec de la API).
  Duration _pollDelay(Duration elapsed) {
    if (elapsed < const Duration(seconds: 30)) return const Duration(seconds: 2);
    if (elapsed < const Duration(seconds: 90)) return const Duration(seconds: 5);
    return const Duration(seconds: 10);
  }

  /// Cancela la espera local; el job sigue en el servidor y se ignora.
  void _cancel() => setState(() {
        _cancelled = true;
        _phase = _Phase.idle;
        _statusText = '';
      });
```

- [ ] **Step 3: Analizar**

```bash
cd ~/cliente-ocr && flutter analyze && flutter test
```

Expected: `No issues found!` + `All tests passed!`

- [ ] **Step 4: Commit**

```bash
cd ~/cliente-ocr && git add lib/main.dart && git commit -m "feat: flujo OCR completo con polling asíncrono, cancelación y copia al portapapeles

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Verificación final y build

**Files:**
- Create (solo si el smoke revela fixes): los ficheros que toque.

**Interfaces:**
- Consumes: la app completa.
- Produces: binario Linux de release + smoke contra la API real con la API key del usuario.

- [ ] **Step 1: Suite completa + build de release**

```bash
cd ~/cliente-ocr && flutter test && flutter analyze && flutter build linux --release
```

Expected: tests OK, analyze limpio, `✓ Built build/linux/x64/release/bundle/cliente_ocr`.

- [ ] **Step 2: Smoke end-to-end contra la API real (pedir la API key al usuario si no se tiene)**

```bash
cd ~/cliente-ocr && flutter run -d linux --release
```

Checklist (cada punto es un paso de verificación, marcar al confirmarlo):

1. Primer arranque sin key → diálogo de Ajustes automático; guardar URL por defecto + API key real.
2. El dropdown carga los tipos del OpenAPI real (no la lista de fallback: comprobar contra https://ocr.reigreengroup.com/docs).
3. Adjuntar una **imagen** pequeña (p. ej. una foto de texto) → spinner «Enviando…» → texto en el panel → Copiar lo pone en el portapapeles.
4. Adjuntar un **PDF** pequeño → «En cola…» → `processing · N s` → resultado en el panel.
5. Botón **Cancelar** durante un job PDF → la UI vuelve a idle sin colgarse.
6. API key incorrecta (editar en Ajustes) → mensaje «API key inválida — revísala en Ajustes», sin crash.
7. Archivo > 50 MB (si hay uno a mano) → rechazo local sin llamar a la API.

- [ ] **Step 3: Commit final si hubo fixes**

```bash
cd ~/cliente-ocr && git add -A && git commit -m "fix: ajustes del smoke end-to-end

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" || echo "sin cambios que commitear"
```

---

## Self-review del plan (hecho al escribirlo)

- **Cobertura de spec:** ajustes+persistencia → Task 4; doc types dinámicos+fallback → Tasks 2/4; adjuntar → Task 5; PDF asíncrono+polling+cancelar → Tasks 3/5; imagen síncrona → Tasks 3/5; resultado+copiar → Task 4/5; errores (401/413/failed/red/timeout) → Tasks 3/5; 50 MB → Task 5; test del parseo → Task 2; build Linux → Tasks 1/6. Sin huecos.
- **Placeholders:** ninguno; todos los pasos tienen código o comando exacto. El único stub (`_pickAndProcess` del Task 4) es deliberado y se reemplaza en Task 5.
- **Consistencia de tipos:** firmas de Task 2/3 (`OcrApiClient`, `OcrJob`, `submitPdf/getJob/ocrImage`) coinciden con su uso en Task 5; `fallbackDocTypes` usado igual en test y en `main.dart`.
