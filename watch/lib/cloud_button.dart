import 'package:flutter/material.dart';

import 'theme.dart';
import 'watch_icon_button.dart';

/// What the cloud button says out loud: whether anyone is signed in, how many
/// reports are waiting for the cloud, and any error. Cloud upload is separate
/// from hospital delivery; this never claims a report reached the hospital.
String cloudButtonLabel({
  required bool signedIn,
  required int pending,
  required bool syncing,
  String? email,
  String? error,
}) {
  final parts = <String>[
    signedIn
        ? 'Cloud account, signed in${email == null ? '' : ' as $email'}'
        : 'Cloud account, signed out',
    if (syncing) 'syncing',
    if (pending > 0)
      pending == 1
          ? '1 report waiting for the cloud'
          : '$pending reports waiting for the cloud',
    if (error != null) 'problem: $error',
  ];
  return parts.join(', ');
}

/// Opens the cloud sign-in or account dialog. Its icon shows signed out, signed
/// in, or syncing, and its badge counts reports waiting for the cloud.
class CloudAccountButton extends StatelessWidget {
  const CloudAccountButton({
    super.key,
    required this.signedIn,
    required this.pending,
    required this.syncing,
    required this.onPressed,
    this.email,
    this.error,
    this.unit = 1,
  });

  final bool signedIn;
  final int pending;
  final bool syncing;
  final String? email;
  final String? error;
  final double unit;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return WatchIconButton(
      icon: !signedIn
          ? Icons.cloud_off_outlined
          : syncing
          ? Icons.cloud_sync_outlined
          : Icons.cloud_done_outlined,
      iconColor: signedIn ? c.accent : c.dim,
      badge: pending,
      badgeColor: error != null ? Colors.orange.shade800 : null,
      unit: unit,
      onPressed: onPressed,
      label: cloudButtonLabel(
        signedIn: signedIn,
        pending: pending,
        syncing: syncing,
        email: email,
        error: error,
      ),
    );
  }
}
