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
  static const _maxBytes = 50 * 1024 * 1024;
  static const _allowedExtensions = ['pdf', 'png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'webp'];

  String _baseUrl = '';
  String _apiKey = '';
  List<String> _docTypes = OcrApiClient.fallbackDocTypes;
  // El texto del campo es la fuente de verdad: admite valores manuales fuera de la lista.
  final _docTypeController = TextEditingController(text: 'general');

  PlatformFile? _file;
  int _fileSize = 0;
  _Phase _phase = _Phase.idle;
  String _statusText = '';
  String _result = '';
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _docTypeController.dispose();
    super.dispose();
  }

  /// Valor efectivo del tipo de documento; vacío → 'general' (default de la API).
  String get _docType {
    final t = _docTypeController.text.trim();
    return t.isEmpty ? 'general' : t;
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
                  child: DropdownMenu<String>(
                    controller: _docTypeController,
                    enabled: !busy,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('Tipo de documento'),
                    inputDecorationTheme: const InputDecorationTheme(
                      border: OutlineInputBorder(),
                    ),
                    dropdownMenuEntries: [
                      for (final t in _docTypes) DropdownMenuEntry(value: t, label: t)
                    ],
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
                '${_file!.name} · ${(_fileSize / 1024 / 1024).toStringAsFixed(1)} MB',
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
      _baseUrl = prefs.getString('base_url') ?? '';
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
                decoration: const InputDecoration(labelText: 'URL base'),
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
            // La URL es obligatoria: sin ella no hay servicio al que llamar.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: urlCtrl,
              builder: (context, value, _) => FilledButton(
                onPressed:
                    value.text.trim().isEmpty ? null : () => Navigator.pop(context, true),
                child: const Text('Guardar'),
              ),
            ),
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
      if (!types.contains(_docTypeController.text)) _docTypeController.text = types.first;
    });
  }

  Future<void> _pickAndProcess() async {
    // file_picker 13.x: pickFiles estático → lista (vacía = cancelado), sin withData
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
    );
    if (picked.isEmpty) return;
    final file = picked.single;
    // file_picker 13.x en Linux (portal XDG): lengthSync() devuelve siempre null.
    // Se leen los bytes una sola vez: valen para el límite de 50 MB, la tarjeta y el submit.
    final bytes = await file.readAsBytes();
    if (bytes.lengthInBytes > _maxBytes) {
      _showSnack('Archivo demasiado grande (máx. 50 MB)', error: true);
      return;
    }
    setState(() {
      _file = file;
      _fileSize = bytes.lengthInBytes;
      _phase = _Phase.working;
      _result = '';
      _error = null;
      _statusText = 'Enviando…';
      _cancelled = false;
    });
    try {
      final client = OcrApiClient(baseUrl: _baseUrl, apiKey: _apiKey);
      // Producción procesa PDF e imágenes por la misma vía asíncrona.
      await _processDoc(client, file, bytes);
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

  /// Submit asíncrono + polling con la estrategia adaptativa de la API.
  Future<void> _processDoc(OcrApiClient client, PlatformFile file, List<int> bytes) async {
    final jobId = await client.submitDoc(bytes, file.name, _docType);
    if (!mounted) return;
    setState(() => _statusText = 'En cola…');
    final start = DateTime.now();
    var pollFailures = 0;
    while (true) {
      await Future.delayed(_pollDelay(DateTime.now().difference(start)));
      if (_cancelled || !mounted) return;
      // Un blip de red no debe perder el job: se toleran hasta 3 fallos seguidos.
      final OcrJob job;
      try {
        job = await client.getJob(jobId);
      } catch (_) {
        if (++pollFailures >= 3) {
          throw OcrApiException(
              'Sin respuesta del servidor tras 3 intentos — el job $jobId puede '
              'seguir procesándose; reintenta más tarde.');
        }
        continue;
      }
      pollFailures = 0;
      if (_cancelled || !mounted) return;
      // El servidor emite finished al terminar (completed por compat); not_found llega como 200.
      if (job.status == 'finished' || job.status == 'completed') {
        setState(() {
          _result = job.result ?? '';
          _phase = _Phase.done;
          _statusText = '';
        });
        return;
      }
      if (job.status == 'failed' || job.status == 'not_found') {
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
