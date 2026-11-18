import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.release});
  final AppUpdateRelease release;
  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final _cancel = CancelToken();
  double? _progress = 0;
  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      final file = await appUpdater.download(widget.release, _cancel, (value) {
        if (mounted) setState(() => _progress = value);
      });
      if (mounted &&
          !_cancel.isCancelled &&
          ModalRoute.of(context)!.isCurrent) {
        Navigator.pop<File>(context, file);
      } else {
        await discardDownloadedUpdate(file);
      }
    } catch (error) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.pop(context);
      dialogs.showNotifier(error.toString(), level: MessageLevel.error);
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return PopScope<File>(
      onPopInvokedWithResult: (didPop, file) {
        if (didPop && file == null) _cancel.cancel();
      },
      child: AlertDialog(
        title: Text(l.updateDownloadInstall),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _progress == null
                  ? l.updateVerifying
                  : '${(_progress! * 100).floor()}%',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
        ],
      ),
    );
  }
}
