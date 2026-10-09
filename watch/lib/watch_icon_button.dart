import 'package:flutter/material.dart';

import 'theme.dart';

/// A round icon button for a watch screen, with an optional count badge in its
/// corner. The spoken [label] replaces anything inside it (the badge number is
/// already part of the label).
class WatchIconButton extends StatelessWidget {
  const WatchIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badge = 0,
    this.iconColor,
    this.badgeColor,
    this.unit = 1,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Shown when above zero, capped at "99+".
  final int badge;
  final Color? iconColor;
  final Color? badgeColor;
  final double unit;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final enabled = onPressed != null;
    final color = enabled ? (iconColor ?? c.text) : c.dim;
    return Semantics(
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      label: label,
      child: GestureDetector(
        onTap: onPressed,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.panel,
                border: Border.all(color: enabled ? c.text : c.dim, width: 2),
              ),
              child: Icon(icon, size: 20 * unit, color: color),
            ),
            if (badge > 0)
              Align(
                alignment: Alignment.topRight,
                child: Container(
                  constraints: BoxConstraints(
                    minWidth: 16 * unit,
                    minHeight: 16 * unit,
                  ),
                  padding: EdgeInsets.symmetric(horizontal: 3 * unit),
                  decoration: BoxDecoration(
                    color: badgeColor ?? c.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  // shrink-wrapped, so the badge stays a small dot in the corner
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      style: TextStyle(
                        color: c.onAccent,
                        fontSize: 10 * unit,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
