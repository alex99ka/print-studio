import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'theme.dart';

/// Photos picked on this device: one from the camera (phone), or several from the gallery / files (PC).
/// No resizing: the originals are design sources.
Future<List<XFile>> pickLogoPhotos({bool camera = false}) async {
  final picker = ImagePicker();
  if (camera) return [?await picker.pickImage(source: ImageSource.camera)];
  return picker.pickMultiImage();
}

bool get canUseCamera => ImagePicker().supportsImageSource(ImageSource.camera);

/// The "camera" and "gallery" buttons, used on the customer page and in the new-customer dialog.
List<Widget> logoPickButtons(void Function(List<XFile>) picked) => [
      if (canUseCamera)
        OutlinedButton.icon(
          onPressed: () async => picked(await pickLogoPhotos(camera: true)),
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('צילום'),
        ),
      OutlinedButton.icon(
        onPressed: () async => picked(await pickLogoPhotos()),
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('תמונות'),
      ),
    ];

/// Photos as thumbnails; add, open, delete. A customer's logos (C-6: the design is made later at the PC)
/// or a request's printed product.
class LogoPhotos extends StatefulWidget {
  const LogoPhotos({super.key, required this.base, this.title = 'תמונות לוגו'});
  final String base; // logosOf / productPhotosOf
  final String title;

  @override
  State<LogoPhotos> createState() => _LogoPhotosState();
}

class _LogoPhotosState extends State<LogoPhotos> {
  late Future<List<Map<String, dynamic>>> _list = photosAt(widget.base);
  final _thumbs = <String, Future<Uint8List>>{};
  bool _busy = false;

  void _reload() => setState(() => _list = photosAt(widget.base));

  Future<void> _add(List<XFile> photos) async {
    if (photos.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await addPhotos(widget.base, photos);
    } catch (e) {
      showError(messenger, e, 'העלאת התמונות נכשלה');
    }
    if (mounted) setState(() => _busy = false);
    _reload();
  }

  Future<void> _delete(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('למחוק את התמונה?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('מחיקה')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await deletePhotoAt(widget.base, id);
    } catch (e) {
      showError(messenger, e, 'מחיקת התמונה נכשלה');
    }
    _reload();
  }

  void _open(String id) => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: FutureBuilder<Uint8List>(
            future: photoAt(widget.base, id),
            builder: (context, s) => s.hasError
                ? Padding(padding: const EdgeInsets.all(24), child: Text(errorText(s.error!, 'טעינת התמונה נכשלה')))
                : !s.hasData
                    ? const SizedBox(width: 200, height: 200, child: Center(child: CircularProgressIndicator()))
                    : InteractiveViewer(maxScale: 8, child: Image.memory(s.data!)),
          ),
        ),
      );

  Widget _thumb(String id) => SizedBox(
        width: 96,
        height: 96,
        child: Stack(children: [
          Positioned.fill(
            child: InkWell(
              onTap: () => _open(id),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: FutureBuilder<Uint8List>(
                  future: _thumbs[id] ??= photoAt(widget.base, id, thumb: 200),
                  builder: (context, s) => s.hasData
                      ? Image.memory(s.data!, fit: BoxFit.cover)
                      : ColoredBox(
                          color: context.studio.sunk,
                          child: s.hasError ? const Icon(Icons.broken_image_outlined) : null),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: IconButton(
              tooltip: 'מחיקה',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(backgroundColor: context.studio.bar, foregroundColor: context.studio.barInk),
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => _delete(id),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _list,
        builder: (context, s) {
          final photos = s.data ?? const [];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${widget.title}${photos.isEmpty ? '' : ' (${photos.length})'}', style: Theme.of(context).textTheme.titleMedium),
              ...logoPickButtons(_add),
            ]),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            if (s.hasError) Text(errorText(s.error!, 'טעינת התמונות נכשלה'), style: TextStyle(color: context.studio.muted)),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final p in photos) _thumb('${p['id']}')]),
          ]);
        },
      );
}
