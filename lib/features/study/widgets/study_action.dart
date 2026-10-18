import 'package:flutter/widgets.dart';

import '../../../shared/widgets/snackbar.dart';

/// Runs a study write and reports a failure in a snackbar instead of letting
/// it escape as an unhandled error. Returns null when the action failed.
Future<T?> runStudyAction<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } catch (e) {
    debugPrint('Study action failed: $e');
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    }
    return null;
  }
}
