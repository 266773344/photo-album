import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../layout/collage_layout.dart';
import '../models/grouping.dart';
import '../models/models.dart';
import 'common.dart';

/// Callbacks and selection state shared by all collage cells of an album.
class CollageInteraction {
  const CollageInteraction({
    required this.selected,
    required this.onOpen,
    required this.onToggle,
    required this.onStartSelection,
    this.flat = false,
  });

  /// Selected photo ids; non-empty means selection mode is active.
  final Set<String> selected;

  /// Open the viewer at this photo (normal mode tap).
  final ValueChanged<Photo> onOpen;
  final ValueChanged<AlbumItem> onToggle;
  final ValueChanged<AlbumItem> onStartSelection;

  /// No drop shadows on cells (airy layout).
  final bool flat;

  bool get selecting => selected.isNotEmpty;
  bool isSelected(AlbumItem item) => item.ids.every(selected.contains);
}

/// Renders one [CollageBlock]: a full-width band with items placed in it.
class CollageBlockView extends StatelessWidget {
  const CollageBlockView({
    super.key,
    required this.block,
    required this.items,
    required this.interaction,
    this.gap = 6,
  });

  final CollageBlock block;

  /// The items the block's cell indices refer to.
  final List<AlbumItem> items;
  final CollageInteraction interaction;
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
                // Keyed by content so a cell's carousel state survives rebuilds.
                key: ValueKey(items[cell.index].stack?.id ?? items[cell.index].photos.first.id),
                item: items[cell.index],
                interaction: interaction,
              ),
            ),
        ],
      ),
    );
  }
}

/// How long a carousel shows each photo before turning to the next.
const carouselInterval = Duration(milliseconds: 4200);

class _Cell extends StatefulWidget {
  const _Cell({super.key, required this.item, required this.interaction});
  final AlbumItem item;
  final CollageInteraction interaction;

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  // Carousels page "infinitely": page index modulo the photo count, so
  // auto-advance always moves forward without a jarring rewind.
  static const _loopBase = 10000;
  PageController? _pages;
  int _page = 0;
  Timer? _timer;
  Timer? _start;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);

  List<Photo> get _ordered {
    // Carousel starts with its cover, then the rest in time order.
    final item = widget.item;
    if (!item.isStack) return item.photos;
    final cover = item.cover;
    return [cover, ...item.photos.where((p) => p.id != cover.id)];
  }

  @override
  void initState() {
    super.initState();
    if (widget.item.isStack) {
      _pages = PageController(initialPage: _loopBase * widget.item.photos.length);
      // Stagger carousels so they don't all turn at the same moment.
      final offset = (widget.item.stack!.id.hashCode & 0x7fffffff) % carouselInterval.inMilliseconds;
      _start = Timer(Duration(milliseconds: offset), () {
        _timer = Timer.periodic(carouselInterval, (_) => _advance());
      });
    }
  }

  void _advance() {
    final pages = _pages;
    if (!mounted || pages == null || !pages.hasClients) return;
    if (widget.interaction.selecting) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    if (!TickerMode.valuesOf(context).enabled) return; // e.g. covered by another route
    if (DateTime.now().difference(_lastTouch) < const Duration(seconds: 8)) return;
    pages.nextPage(duration: const Duration(milliseconds: 650), curve: Curves.easeInOutCubic);
  }

  @override
  void didUpdateWidget(covariant _Cell old) {
    super.didUpdateWidget(old);
    if (_page >= widget.item.photos.length) _page = 0;
  }

  @override
  void dispose() {
    _start?.cancel();
    _timer?.cancel();
    _pages?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final ia = widget.interaction;
    final scheme = Theme.of(context).colorScheme;
    final selected = ia.isSelected(item);
    final photos = _ordered;
    final current = photos[_page.clamp(0, photos.length - 1)];

    Widget content;
    if (item.isStack) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollStartNotification>(
            onNotification: (n) {
              if (n.dragDetails != null) _lastTouch = DateTime.now();
              return false;
            },
            child: PageView.builder(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i % photos.length),
              itemBuilder: (_, i) => _CarouselPage(photo: photos[i % photos.length], cellAspect: item.aspect),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: current.caption.isEmpty ? 8 : 40,
            child: IgnorePointer(child: _Dots(count: photos.length, index: _page)),
          ),
        ],
      );
    } else {
      content = PhotoThumb(photo: current, heroTag: 'photo_${current.id}');
    }

    return LayoutBuilder(builder: (context, size) {
      // Captions only where there's room for them; the viewer always shows them.
      final showCaption = current.caption.isNotEmpty && size.maxHeight >= 130 && size.maxWidth >= 130;
      return AnimatedScale(
        scale: selected ? 0.9 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          elevation: selected || ia.flat ? 0 : 1.5,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              content,
              if (showCaption) _Caption(text: current.caption),
              // Gesture layer. For carousels it must let horizontal drags reach
              // the PageView, so it only listens for taps and long presses.
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => ia.selecting ? ia.onToggle(item) : ia.onOpen(current),
                onLongPress: () => ia.selecting ? ia.onToggle(item) : ia.onStartSelection(item),
              ),
              if (ia.selecting)
                IgnorePointer(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: selected ? scheme.primary.withValues(alpha: 0.18) : Colors.transparent,
                      border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 3),
                    ),
                    alignment: Alignment.topLeft,
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      selected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: selected ? scheme.primary : Colors.white,
                      shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

/// One photo inside a carousel cell. The cell has the cover photo's shape;
/// photos with a noticeably different shape are shown whole ("contain") on a
/// soft, blurred copy of themselves instead of being cropped.
class _CarouselPage extends StatelessWidget {
  const _CarouselPage({required this.photo, required this.cellAspect});
  final Photo photo;
  final double cellAspect;

  @override
  Widget build(BuildContext context) {
    final fits = (math.log(photo.aspect / cellAspect)).abs() < 0.06;
    final thumb = PhotoThumb(
      photo: photo,
      heroTag: 'photo_${photo.id}',
      fit: fits ? BoxFit.cover : BoxFit.contain,
      transparent: !fits,
    );
    if (fits) return thumb;
    final repo = AlbumScope.read(context);
    final base = photo.palette.isEmpty ? Colors.grey : Color(photo.palette.first.argb);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: base),
          // A tiny decode, scaled up and blurred: cheap and soft.
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10, tileMode: TileMode.clamp),
            child: Image(
              image: ResizeImage(StoredImage(repo, photo.thumbKey), width: 32, policy: ResizeImagePolicy.fit),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const ColoredBox(color: Color(0x22000000)),
          thumb,
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final shown = count.clamp(0, 7);
    // For long carousels, keep the active dot visible within a 7-dot window.
    final start = (index - shown ~/ 2).clamp(0, count - shown);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = start; i < start + shown; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            width: i == index ? 14 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: i == index ? Colors.white : Colors.white60,
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
            ),
          ),
      ],
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
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
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.25),
                ),
              ),
            ),
          ),
        ),
      );
}
