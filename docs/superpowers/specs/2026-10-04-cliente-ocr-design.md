# Cliente OCR de escritorio — Diseño

- **Fecha:** 2026-10-04
- **Estado:** aprobado por el usuario
- **Stack:** Flutter (desktop Linux), proyecto en `~/cliente-ocr`

## Objetivo

App de escritorio para consumir el microservicio OCR propio (`https://ocr.reigreengroup.com`):

1. Configurar el token de acceso (persistente).
2. Recuperar dinámicamente los tipos de documento disponibles.
3. Adjuntar un PDF o una imagen.
4. Recibir el texto OCR procesado **sin bloquear la UI** (espera asíncrona con feedback de estado).

## API (v2.0.0) — comportamiento real de producción

> Actualizado tras la prueba en vivo (2026-10-04). Directiva: el cliente se adapta a
> producción; no se propone fix del servidor.

- **Auth:** header `X-API-Key` (no Bearer). Públicos: `/ocr/health`, `/ocr/models`, `/ocr/jobs/{job_id}`, `GET /`.
- **Vía única operativa:** `POST /ocr/async/pdf` (multipart: `file`, `doc_type`) → `{job_id, status: queued}` → `GET /ocr/jobs/{job_id}`. Acepta **PDF e imágenes** por la misma vía.
- **Estados reales del job:** `queued → started → finished` (con `result`) | `failed` (con `error`). No existen `processing`/`completed` (el cliente los acepta solo por compatibilidad defensiva). Un job inexistente responde **HTTP 200** con `{"status": "not_found", "error": ...}`, no 404.
- **`result`:** es un **objeto** con el texto anidado en `result.ocr_result` (no un string plano). El cliente lo resuelve anidado y acepta string plano como fallback. El texto pasa por `fixMojibake` (`api_client.dart`): recodifica UTF-8 que llegó leído como Latin-1; si la recodificación produce U+FFFD se devuelve el original intacto.
- **`POST /ocr` síncrono:** documentado en el OpenAPI (JSON: `file` base64), pero responde 500 en producción (`'OCRRequest' object has no attribute 'image'`). Bug del servidor: no se usa.
- **Tipos de documento:** enum `doc_type` en el esquema OpenAPI (`/openapi.json`, campo `doc_type` del multipart de `/ocr/async/pdf`). No hay endpoint propio. Valores actuales: `general`, `contrato`, `table`, `handwriting`, `scan`, `auto_detect`, `company_3…29`, `tarifas_15/17/24`.
- **Límites:** PDF/PNG/JPEG/BMP/TIFF/WebP, máx. 50 MB. Rate limit 60 req/min.
- **Polling** (estrategia sugerida por la propia API): 2 s durante los primeros 30 s, 5 s hasta 90 s, 10 s después.

**Nota file_picker (Linux):** en file_picker 13.x sobre el portal XDG, `PlatformFile.lengthSync()` devuelve siempre `null` (el picker entrega solo la ruta). Para el chequeo de 50 MB y para mostrar el tamaño hay que leer los bytes: `file.readAsBytes()` y `bytes.lengthInBytes`.

## Arquitectura

Una ventana, una pantalla. `setState` para el estado (no hay estado que merezca Riverpod/Bloc).

**Dependencias (solo 3):** `http`, `file_picker`, `shared_preferences`.

**Componentes:**

- `lib/api_client.dart` — `OcrApiClient`:
  - `getDocTypes()`: descarga `/openapi.json`, extrae el enum de `doc_type`; fallback a lista embebida si falla la descarga.
  - `submitDoc(bytes, filename, docType)` → `jobId` (única vía; sirve para PDF e imágenes).
  - `getJob(jobId)` → `{status, result?, error?}`.
  - Header `X-API-Key` en todas las llamadas protegidas; timeout explícito en cada request.
- `lib/main.dart` — pantalla única: ajustes (URL base + API key en diálogo, persistentes en `shared_preferences`, se abren al primer arranque si falta la key), selector de tipo de documento editable (lista del OpenAPI como sugerencias, acepta valor manual), botón de adjuntar (PDF/imagen), panel de resultado.

## Flujo de procesamiento

1. Usuario adjunta archivo → se leen los bytes una vez (`readAsBytes()`, ver nota file_picker) y se valida el máximo local de 50 MB → se muestra nombre, tamaño y spinner «Enviando…».
2. **Todos los documentos** (PDF e imágenes): `submitDoc` → bucle de polling con la estrategia adaptativa; muestra el estado real (`queued`/`started`) y tiempo transcurrido. Cancelable: el botón Cancelar abandona la espera (el job sigue en el servidor, se ignora).
3. Resultado → `SelectableText` scrolleable + botón **Copiar**.

## Gestión de errores

- Timeout en cada request (el polling es quien tolera trabajos largos): `openapi.json` 15 s, submit 120 s, `getJob` 30 s.
- `401` → SnackBar sugiriendo revisar la API key (y abrir ajustes).
- `413` → archivo > 50 MB.
- Job `failed`/`not_found` → mostrar el `error` devuelto por el servidor.
- Fallo de red / servidor caído → mensaje claro, sin colgar la UI. El bucle de polling tolera hasta 3 fallos consecutivos de `getJob` (blips de red) antes de abortar; el contador se resetea con cada respuesta correcta.

## Testing

Un test `assert`-based del parseo del enum `doc_type` desde un `openapi.json` de ejemplo (la única lógica no trivial, incluye el fallback). El resto es pegamento de UI — sin mocks de red (YAGNI).

## Fuera de scope

- Pipelines `/ocr/hybrid` y `/ocr/inspector` (devuelven JSON estructurado; aquí se quiere texto).
- Webhooks, histórico de trabajos, cola local.
- Multiplataforma: se compila Linux; Flutter permite Windows/Mac después sin cambiar código.
