import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_info.dart';

/// Marks a widget the tour can point at, by name. Several may carry the same
/// name (the back arrow on every screen, a section in each tab): the tour
/// takes the one that is on screen.
class TourTarget extends StatefulWidget {
  const TourTarget(this.id, {super.key, required this.child});

  final String id;
  final Widget child;

  static final _all = <String, Set<BuildContext>>{};

  /// Some widget is named [id], on screen or not (say, a route still opening).
  static bool exists(String id) => _all[id]?.isNotEmpty ?? false;

  /// The widget named [id] that she can see now: on the top route, in the
  /// shown section, laid out.
  static BuildContext? find(String id) {
    for (final context in _all[id] ?? const <BuildContext>{}) {
      final box = context.findRenderObject();
      if (context.mounted &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          Visibility.of(context) &&
          box is RenderBox &&
          box.attached &&
          box.hasSize) {
        return context;
      }
    }
    return null;
  }

  @override
  State<TourTarget> createState() => _TourTargetState();
}

class _TourTargetState extends State<TourTarget> {
  @override
  void initState() {
    super.initState();
    TourTarget._all.putIfAbsent(widget.id, () => {}).add(context);
  }

  @override
  void didUpdateWidget(TourTarget old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      TourTarget._all[old.id]?.remove(context);
      TourTarget._all.putIfAbsent(widget.id, () => {}).add(context);
    }
  }

  @override
  void dispose() {
    TourTarget._all[widget.id]?.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class TourStep {
  const TourStep(
    this.title,
    this.body, {
    this.target,
    this.tap = false,
    this.section,
    this.optional = false,
    this.since = const [],
  });

  final String title;
  final String body;

  /// The [TourTarget] to spotlight; without one (or when it can't be found)
  /// the card is centered.
  final String? target;

  /// She moves on by tapping the target, which does what it always does. Only
  /// for taps that open or close something: never send, save or delete.
  final bool tap;

  /// The app section to show first (see the shell's sections).
  final int? section;

  /// Skipped when its target isn't there, e.g. no projects yet to open.
  final bool optional;

  /// The versions that brought it (or need it to reach a new step): the tour
  /// after such an update shows it.
  final List<String> since;
}


/// The whole app, step by step. Every user-facing release adds steps for what
/// it brought, tagged with its version in [TourStep.since]; the what's-new
/// tour after an update shows exactly those. Never make the user tap
/// something that sends, deletes, pays or calls a paid API: explain it.
final fullTour = <TourStep>[
  const TourStep(
    'סיור באפליקציה',
    'בכל שלב מסומן משהו במסך. כשכתוב "לחצו", לוחצים עליו ממש, כמו בשימוש '
        'רגיל. בסיור שום דבר לא נשלח ולא נמחק, ואפשר לדלג בכל רגע.',
  ),
  const TourStep(
    'הוספה מהירה',
    'כותבים ולוחצים Enter, וממשיכים לכתוב. כל מי שבבית רואה את זה מיד.',
    target: 'home.add',
  ),
  const TourStep(
    'פעולות על פריט',
    'לחיצה ארוכה על פריט פותחת עריכה ומחיקה. מחיקה אפשר לבטל מההודעה שעולה.',
    target: 'home.first',
    optional: true,
  ),
  const TourStep(
    'הגדרות',
    'לחצו על גלגל השיניים.',
    target: 'settings',
    tap: true,
  ),
  const TourStep(
    'עדכונים',
    'האפליקציה מתעדכנת לבד ברקע. כאן אפשר גם לבדוק עכשיו.',
    target: 'settings.update',
  ),
  const TourStep(
    'טביעת אצבע',
    'כניסה בטביעת אצבע במקום Google בכל פעם.',
    target: 'settings.fingerprint',
    optional: true,
  ),
  const TourStep(
    'משהו לא עובד?',
    '"דיווח על בעיה" שולח את הפרטים ישר לבונה האפליקציה. "מצב המערכת" מראה '
        'מה תקין ומה לא.',
    target: 'settings.report',
  ),
  const TourStep(
    'זהו!',
    'כשמשהו נכשל, ההודעה אומרת מה קרה, מה עושים, וקוד. אחרי כל עדכון יופיע '
        'סיור קצר במה שחדש, והסיור המלא נמצא כאן בהגדרות.',
    target: 'settings.tour',
  ),
];

/// The steps of the versions after [seen] up to [version], with a welcome
/// and a goodbye; empty when those versions brought no steps.
List<TourStep> whatsNew(String seen, String version) {
  final steps = [
    for (final s in fullTour)
      if (s.since.any((v) => isNewer(v, seen) && !isNewer(v, version))) s,
  ];
  if (steps.isEmpty) return const [];
  return [
    TourStep(
      'מה חדש בגרסה $version',
      'סיור קצר במה שנוסף. לוחצים על מה שמסומן, ואפשר לדלג בכל רגע.',
    ),
    ...steps,
    const TourStep('זהו!', 'הסיור המלא נמצא תמיד בהגדרות > סיור באפליקציה.'),
  ];
}

const _versionKey = 'tour_version';

/// What this launch shows: the whole tour on a new device, the new version's
/// steps after an update (empty when it has none: then its notes), or
/// nothing (null).
Future<List<TourStep>?> tourForThisLaunch(String version) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getString(_versionKey);
    await prefs.setString(_versionKey, version);
    if (seen == null) return fullTour;
    return isNewer(version, seen) ? whatsNew(seen, version) : null;
  } catch (_) {
    return null; // no storage: don't nag on every launch
  }
}

/// The tour running now, shown by [TourLayer] over every screen.
final runningTour = ValueNotifier<List<TourStep>?>(null);

/// Set by the shell: shows one of its sections.
ValueChanged<int>? showSection;

/// Over the whole app (routes included), so the tour follows her into the
/// screens she opens.
class TourLayer extends StatelessWidget {
  const TourLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: runningTour,
      builder: (context, steps, _) => Stack(
        children: [
          child,
          if (steps != null)
            Positioned.fill(
              child: TourOverlay(
                key: ObjectKey(steps),
                steps: steps,
                onSection: (i) => showSection?.call(i),
                onDone: () => runningTour.value = null,
              ),
            ),
        ],
      ),
    );
  }
}

/// Dims the app except the current step's target, with an explanation card.
/// On a [TourStep.tap] step the target takes the tap, and the tour follows.
class TourOverlay extends StatefulWidget {
  const TourOverlay({
    super.key,
    required this.steps,
    required this.onSection,
    required this.onDone,
  });

  final List<TourStep> steps;
  final ValueChanged<int> onSection;
  final VoidCallback onDone;

  @override
  State<TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<TourOverlay> {
  int _i = 0;
  Rect? _hole;
  bool _ready = false; // the card is up (its target found, or given up on)
  Offset? _down;

  @override
  void initState() {
    super.initState();
    _go(0);
  }

  Future<void> _go(int i, {bool back = false}) async {
    if (i >= widget.steps.length) return widget.onDone();
    final step = widget.steps[i];
    setState(() {
      _i = i;
      _hole = null;
      _ready = false;
    });
    if (step.section case final section?) widget.onSection(section);
    final hole = step.target == null ? null : await _find(step, i);
    if (!mounted || _i != i) return;
    if (hole == null && step.optional && (i > 0 || !back)) {
      return _go(back ? i - 1 : i + 1, back: back);
    }
    setState(() {
      _hole = hole;
      _ready = true;
    });
  }

  /// Where the step's target is, once it's on screen and stopped moving (a
  /// route opening, a tab sliding in, a scroll); null if it doesn't come.
  Future<Rect?> _find(TourStep step, int i) async {
    final id = step.target!;
    Rect? last;
    var scrolled = false;
    for (var tries = 0; tries < 30; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted || _i != i) return null;
      // Not even built (no projects to open): don't keep her waiting.
      if (step.optional && !TourTarget.exists(id)) return null;
      final target = TourTarget.find(id);
      if (target == null || !target.mounted) continue;
      if (!scrolled) {
        scrolled = true;
        await Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: const Duration(milliseconds: 250),
        );
        continue;
      }
      final rect = _rectOf(target);
      if (rect != null && rect == last) return rect.inflate(6);
      last = rect;
    }
    return null;
  }

  Rect? _rectOf(BuildContext target) {
    final box = target.findRenderObject() as RenderBox?;
    final overlay = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || overlay == null) return null;
    final screen = Offset.zero & overlay.size;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    return rect.overlaps(screen) ? rect.intersect(screen) : null;
  }

  /// The target took her tap: on to the next step once it has done its thing.
  void _tapped(Offset up) {
    final down = _down;
    _down = null;
    final hole = _hole;
    if (!_ready || !widget.steps[_i].tap || hole == null || down == null) {
      return;
    }
    if (!hole.contains(down) || (up - down).distance > 24) return;
    setState(() => _ready = false);
    _go(_i + 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = widget.steps[_i];
    final last = _i == widget.steps.length - 1;
    final hole = _hole;
    // On a tap step the target is the way on; "הבא" only if it can't be found.
    final tapHere = step.tap && hole != null;
    final card = Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(step.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(step.body, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${_i + 1}/${widget.steps.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (!last)
                  TextButton(
                    onPressed: widget.onDone,
                    child: const Text('דילוג'),
                  ),
                // Not back over a tap: what it opened is open now.
                if (_i > 0 && !widget.steps[_i - 1].tap)
                  TextButton(
                    onPressed: () => _go(_i - 1, back: true),
                    child: const Text('הקודם'),
                  ),
                if (!tapHere)
                  FilledButton(
                    onPressed: last ? widget.onDone : () => _go(_i + 1),
                    child: Text(last ? 'סיום' : 'הבא'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return Listener(
      // Sees the tap on the target without taking it from the app below.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down = e.localPosition,
      onPointerUp: (e) => _tapped(e.localPosition),
      child: LayoutBuilder(
        builder: (context, size) {
          final room = hole == null
              ? 0.0
              : (hole.top > size.maxHeight - hole.bottom
                    ? hole.top
                    : size.maxHeight - hole.bottom);
          final below =
              hole != null && hole.top <= size.maxHeight - hole.bottom;
          return Stack(
            children: [
              Positioned.fill(
                // Everything but the hole of a tap step waits under the tour.
                child: ClipPath(
                  clipper: tapHere && _ready ? _OutsideOf(hole) : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    child: CustomPaint(
                      painter: _Spotlight(
                        _ready ? hole : null,
                        theme.colorScheme.scrim.withValues(
                          alpha: _ready ? 0.72 : 0.4,
                        ),
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
              if (_ready)
                if (hole == null)
                  Positioned.fill(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: card,
                      ),
                    ),
                  )
                else
                  Positioned(
                    left: 0,
                    right: 0,
                    // A target too tall to leave room: the card at the bottom.
                    top: room < 200 ? null : (below ? hole.bottom + 8 : null),
                    bottom: room < 200
                        ? 0
                        : (below ? null : size.maxHeight - hole.top + 8),
                    child: SafeArea(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: card,
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// Everything except [hole]: where the tour takes taps.
class _OutsideOf extends CustomClipper<Path> {
  _OutsideOf(this.hole);

  final Rect hole;

  @override
  Path getClip(Size size) => Path.combine(
    PathOperation.difference,
    Path()..addRect(Offset.zero & size),
    Path()..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(16))),
  );

  @override
  bool shouldReclip(_OutsideOf old) => old.hole != hole;
}

class _Spotlight extends CustomPainter {
  _Spotlight(this.hole, this.scrim, this.ring);

  final Rect? hole;
  final Color scrim;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final everything = Path()..addRect(Offset.zero & size);
    final hole = this.hole;
    if (hole == null) {
      canvas.drawPath(everything, Paint()..color = scrim);
      return;
    }
    final spot = RRect.fromRectAndRadius(hole, const Radius.circular(16));
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        everything,
        Path()..addRRect(spot),
      ),
      Paint()..color = scrim,
    );
    canvas.drawRRect(
      spot,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_Spotlight old) =>
      old.hole != hole || old.scrim != scrim || old.ring != ring;
}
