import 'package:material_ui/material_ui.dart';

import '../layout/collage_layout.dart';
import '../models/models.dart';
import 'common.dart';

/// Renders one [CollageBlock]: a full-width band with photos placed in it.
class CollageBlockView extends StatelessWidget {
  const CollageBlockView({
    super.key,
    required this.block,
    required this.photos,
    required this.onTap,
    required this.onLongPress,
    this.gap = 6,
  });

  final CollageBlock block;

  /// The photos the block's cell indices refer to.
  final List<Photo> photos;
  final ValueChanged<Photo> onTap;
  final ValueChanged<Photo> onLongPress;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: block.width,
      height: block.height,
      child: Stack(
        children: [
          for (final cell in block.cells)
            Positioned.fromRect(
              rect: cell.rect.deflate(gap / 2),
              child: _Cell(
                photo: photos[cell.index],
                onTap: onTap,
                onLongPress: onLongPress,
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.photo, required this.onTap, required this.onLongPress});
  final Photo photo;
  final ValueChanged<Photo> onTap;
  final ValueChanged<Photo> onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 1.5,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoThumb(photo: photo, heroTag: 'photo_${photo.id}'),
          if (photo.caption.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xAA000000), Color(0x00000000)],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                    child: Text(
                      photo.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.25),
                    ),
                  ),
                ),
              ),
            ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onTap(photo),
              onLongPress: () => onLongPress(photo),
            ),
          ),
        ],
      ),
    );
  }
}
