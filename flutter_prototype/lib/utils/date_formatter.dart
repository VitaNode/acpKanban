import 'package:intl/intl.dart';

class DateFormatter {
  static String formatFull(String dateTimeStr) {
    try {
      final dt = DateTime.parse(dateTimeStr);
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (e) {
      return dateTimeStr;
    }
  }

  static String formatTimeOnly(String dateTimeStr) {
    try {
      final dt = DateTime.parse(dateTimeStr);
      return DateFormat('HH:mm').format(dt);
    } catch (e) {
      return dateTimeStr;
    }
  }

  static String formatShortDate(String dateTimeStr) {
    try {
      final dt = DateTime.parse(dateTimeStr);
      return DateFormat('MM/dd HH:mm').format(dt);
    } catch (e) {
      return dateTimeStr;
    }
  }

  static String formatRelative(String dateTimeStr) {
    try {
      final DateTime dateTime = DateTime.parse(dateTimeStr);
      final DateTime now = DateTime.now();
      final difference = now.difference(dateTime).inSeconds;

      if (difference < 0) {
        // Future time, fallback to absolute
        return DateFormat('HH:mm').format(dateTime);
      }

      if (difference < 5) {
        return 'just now';
      } else if (difference < 60) {
        return '$difference seconds ago';
      } else if (difference < 3600) {
        final minutes = (difference / 60).floor();
        return '$minutes minute${minutes == 1 ? '' : 's'} ago';
      } else if (difference < 86400) {
        final hours = (difference / 3600).floor();
        return '$hours hour${hours == 1 ? '' : 's'} ago';
      } else if (difference < 604800) {
        final days = (difference / 86400).floor();
        return '$days day${days == 1 ? '' : 's'} ago';
      } else {
        // More than a week, show date
        return DateFormat('MM/dd/yyyy').format(dateTime);
      }
    } catch (e) {
      return dateTimeStr;
    }
  }
}
