import 'package:flutter/material.dart';

/// Thin FutureBuilder wrapper so every screen renders loading/error/empty
/// states the same way, instead of re-deriving that logic per screen.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.future,
    required this.builder,
    this.isEmpty,
    this.emptyMessage = 'No data for the current filters.',
  });

  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // RepaintBoundary — Craig, 2026-08-26: "The timing wheel stops
          // turning / updating." This is the one loading spinner almost
          // every screen in the app shows while its data is in flight.
          // CircularProgressIndicator drives itself with an implicit
          // AnimationController; isolating it in its own repaint layer
          // stops an unrelated ancestor rebuild (a filter chip changing, a
          // sibling's setState, anything upstream re-laying-out this
          // subtree) from forcing this spinner through a relayout/repaint
          // cycle of its own, which is what made it look like it paused.
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: RepaintBoundary(child: CircularProgressIndicator()),
            ),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Something went wrong loading this: ${snapshot.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null || (isEmpty != null && isEmpty!(data))) {
          return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(emptyMessage)));
        }
        return builder(context, data);
      },
    );
  }
}
