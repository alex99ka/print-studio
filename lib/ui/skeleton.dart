import 'package:flutter/material.dart';

import 'theme.dart';

/// Placeholder rows shaped like the content while it loads: never a lone
/// spinner. A soft pulse, still when the system asks for reduced motion.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.rows = 6, this.leading = true});

  final int rows;
  final bool leading;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final color = skeletonColor(context);
    Widget box(double w, double h, {double r = 6}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(r)),
        );
    final list = ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.rows,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          if (widget.leading) ...[box(40, 40, r: 20), const SizedBox(width: 16)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Varying widths, so it reads as text and not as a grid.
                FractionallySizedBox(
                    widthFactor: 0.5 + (i % 3) * 0.15, child: box(0, 14)),
                const SizedBox(height: 8),
                FractionallySizedBox(widthFactor: 0.35, child: box(0, 10)),
              ],
            ),
          ),
        ]),
      ),
    );
    return Semantics(
      label: 'טוען…',
      child: still
          ? list
          : FadeTransition(
              opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
              child: list),
    );
  }
}
