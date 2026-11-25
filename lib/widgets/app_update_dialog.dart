import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class AppUpdateDialog extends ConsumerWidget {
  const AppUpdateDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.appLocalizations;
    final progress = ref.watch(
      appUpdateActivityProvider.select((activity) => activity?.progress),
    );
    return AlertDialog(
      title: Text(l.updateDownloadInstall),
      content: AppUpdateProgress(progress: progress),
      actions: [
        TextButton(
          onPressed: () =>
              ref.read(commonActionProvider.notifier).cancelUpdate(),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.updateContinueInBackground),
        ),
      ],
    );
  }
}

class AppUpdateProgress extends StatelessWidget {
  const AppUpdateProgress({super.key, this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final progress = this.progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(
          progress == null
              ? context.appLocalizations.updateVerifying
              : '${(progress * 100).floor()}%',
        ),
        LinearProgressIndicator(value: progress),
      ],
    );
  }
}
