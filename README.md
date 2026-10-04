# cliente_ocr

Cliente de escritorio (Flutter/Linux) para el microservicio OCR
(`https://github.com/eztornado/ocr-microservice`). Permite configurar la API key, elegir el tipo
de documento, adjuntar un PDF o una imagen y recibir el texto OCR en la misma
ventana, sin bloquear la UI mientras se procesa.

## Qué hace

1. **Ajustes** (primer arranque o desde la barra superior): URL base del
   servicio y API key, persistentes entre sesiones.
2. **Tipos de documento**: se descargan del `openapi.json` del servicio (con
   lista de respaldo embebida) y el campo también acepta un valor escrito a mano.
3. **Procesado**: se adjunta un PDF o imagen (pdf, png, jpg, jpeg, bmp, tif,
   tiff, webp; máx. 50 MB) y se envía por `POST /ocr/async/pdf`. La app hace
   polling de `GET /ocr/jobs/{id}` (estados `queued → started → finished`) y
   muestra el estado y el tiempo transcurrido; se puede cancelar la espera.
4. **Resultado**: el texto OCR aparece en un panel seleccionable con botón de
   copiar. Los errores de la API (401, 413, job `failed`, red) se muestran
   como mensajes claros.

Notas sobre la API real (v2.0.0): la única vía operativa es la asíncrona
(acepta PDF **e imágenes**); el endpoint síncrono `POST /ocr` responde 500 en
producción y no se usa. El resultado llega como objeto con el texto en
`ocr_result`. La autenticación es por header `X-API-Key`. El texto recibido
pasa por una corrección de mojibake (UTF-8 leído como Latin-1) antes de
mostrarse.

## Tecnologías

- **Flutter** (desktop Linux; portátil a Windows/Mac sin cambiar código).
- **http** — llamadas REST (subida multipart, polling, OpenAPI).
- **file_picker** — selección de PDF/imagen.
- **shared_preferences** — persistencia de URL base y API key.
- Tests: `flutter test` (parseo del enum de `doc_type` y corrección de mojibake).

## Configuración y ejecución

Requisitos: SDK de Flutter en el PATH y las librerías de desarrollo de GTK/Linux
(`libgtk-3-dev`, `ninja-build`, `clang`, `pkg-config`, `liblzma`).

```bash
cd ~/cliente-ocr
flutter pub get
flutter run -d linux              # en desarrollo
flutter build linux --release     # binario: build/linux/x64/release/bundle/cliente_ocr
flutter test                      # tests
```

Al primer arranque la app abre el diálogo de Ajustes, donde se introducen:

- **URL base**: `https://ocr.reigreengroup.com` (sin barra final).
- **API key**: la clave del microservicio (header `X-API-Key`).

Ambos valores se guardan en
`~/.local/share/com.eztornado.cliente_ocr/shared_preferences.json` (claves
`flutter.base_url` y `flutter.api_key`) y no hay que volver a escribirlos.
