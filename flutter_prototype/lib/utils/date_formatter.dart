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
}
