import 'dart:async';
import 'dart:io';

import 'package:flutter_fimber/flutter_fimber.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'file_logger_utils.dart';

/// A tree that will write logs to a file.
/// A new file will be created each day.
///
/// - Directory:
///   [getApplicationDocumentsDirectory]/logs
///
/// - File pattern:
///   [_fileDateFormat].log
///
/// You can also provide the number of days to keep the files on the disk with
/// the [numberOfDays] attribute
///
class FileLoggerTree extends LogTree {
  /// The levels for the [LogTree]
  final List<String> levels;

  /// The number of days to keep the log files onto the disk
  /// If you want to disable the auto-clean mechanism, just pass a null value
  final int? numberOfDays;

  /// The size of file (mb) to keep the log files onto the disk
  /// If you want to disable the auto-clean mechanism, just pass a null value
  final int? maxSize;

  /// The format for each file (eg: yyyy-MM-dd => 2019-08-24.log)
  final String fileDateFormat;

  /// The format of the date before each log
  final String logDateFormat;

  // Internal stuff
  final StringBuffer _buffer;
  final Lock _lock;
  Directory? _directory;
  late File _file;
  DateTime? _fileDate;

  /// Instantiate a new tree for [Fimber] that will write the logs to disk
  ///
  /// You have to provide the [levels] of the logs that will be received
  ///
  /// You also have to specify the number of days to keep the files on the disk
  /// with the [numberOfDays] attribute (must >= 1)
  ///
  /// Finally, you can specify the format of the date before each log with
  /// [logItemDateFormat]
  ///
  /// The logs will be store in the following folder
  /// [getApplicationDocumentsDirectory]/logs
  FileLoggerTree(
      {this.levels = FileLoggerLevels.ALL,
      this.numberOfDays = 1,
      this.maxSize = null,
      this.logDateFormat = 'MM/dd/yyyy HH:mm:ss',
      this.fileDateFormat = 'yyyy-MM-dd',
      String? locale})
      : assert(numberOfDays == null || numberOfDays >= 1,
            'The number of days must be null (auto-clean disabled) or >= 1'),
        assert(maxSize == null || maxSize >= 1,
            'The max size must be null (max-size disabled) or >= 1'),
        _lock = Lock(),
        _buffer = StringBuffer();

  /// Returns the directory where the files are stored
  Directory? get directory => _directory;

  Future<void> _init() async {
    String baseDirPath;
    if (Platform.isAndroid) {
      baseDirPath = (await getExternalStorageDirectory())!.path;
    } else if (Platform.isIOS) {
      baseDirPath = (await getApplicationDocumentsDirectory()).path;
    } else {
      throw Exception('Platform is not support');
    }
    baseDirPath = '$baseDirPath/';

    _directory = Directory(path.join(baseDirPath, 'logs'));
    await _directory!.create();

    await _cleanFiles();
  }

  Future<void> _cleanFiles() async {
    if (numberOfDays != null) {
      List<FileSystemEntity> files =
          await FileLoggerUtils.listDirContentsAsync(_directory!);
      DateTime now = DateTime.now();

      DateTime minDate = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: numberOfDays! - 1));

      for (FileSystemEntity file in files) {
        DateTime date =
            _fileDateFormat.parse(path.basenameWithoutExtension(file.path));

        if (date.isBefore(minDate)) {
          await file.delete();
        }
      }
    }

    _fileDate = DateTime.now();

    int fileIndex = 0;
    //get the list of files
    List<FileSystemEntity> files =
        await FileLoggerUtils.listDirContentsAsync(_directory!);

    if (files.isNotEmpty) {
      //this map method will return a list of exist index of "today file"
      List<int> indexList = files.map((FileSystemEntity file) {
        //split name file and index. Format: [fileName_index]
        //0: file name
        //1: index
        List<String> fileNameIndex =
            path.basenameWithoutExtension(file.path).split('_');
        if (fileNameIndex[0] == '${_fileDateFormat.format(_fileDate!)}') {
          int index = 0;
          try {
            index = int.parse(fileNameIndex[1]);
          } catch (e) {}
          return index;
        } else {
          //if file isn't "today file", don't get index, return 0 mean it will not effect other "today file"
          return 0;
        }
      }).toList();
      indexList.sort();
      //get the max index (the current index)
      fileIndex = indexList.last;
    }

    _file = File(path.join(_directory!.path,
        '${_fileDateFormat.format(_fileDate!)}_$fileIndex.txt'));
    if (this.maxSize == null) {
      return;
    }
    //if file > 1MB create new file with index = index + 1
    if (_file.existsSync() && _file.lengthSync() > maxSize! * 1000000) {
      _file = File(path.join(_directory!.path,
          '${_fileDateFormat.format(_fileDate!)}_${fileIndex + 1}.txt'));
    }
  }

  @override
  List<String> getLevels() => levels;

  @override
  void log(String level, String msg,
      {String? tag, Object? ex, StackTrace? stacktrace}) {
    _logAsync(level, msg, tag: tag, ex: ex, stacktrace: stacktrace);
  }

  void _logAsync(String level, String msg,
      {String? tag, Object? ex, StackTrace? stacktrace}) async {
    await _lock.synchronized(() async {
      if (_fileDate == null) {
        await _init();
      }

      if (!FileLoggerUtils.isSameDay(DateTime.now(), _fileDate!)) {
        await _cleanFiles();
      }

      await _file.writeAsString(_getLog(tag, level, msg, ex, stacktrace),
          mode: FileMode.writeOnlyAppend, flush: true);
    });
  }

  String _getLog(String? tag, String level, String msg, Object? ex,
      StackTrace? stacktrace) {
    _buffer.clear();

    _buffer.write(_formattedDateTime);
    _buffer.write(' [');
    if (tag != null) {
      _buffer.write(tag);
      _buffer.write('-');
    }
    _buffer.write(level);
    _buffer.write(']:');
    _buffer.writeln(msg);

    if (ex != null) {
      _buffer.writeln(ex.toString());
    }

    if (stacktrace != null) {
      _buffer.writeln(stacktrace.toString());
    }

    return _buffer.toString();
  }

  String get _formattedDateTime => _logDateFormat.format(DateTime.now());

  DateFormat get _fileDateFormat => DateFormat(fileDateFormat);

  DateFormat get _logDateFormat => DateFormat(logDateFormat);
}

class FileLoggerLevels {
  const FileLoggerLevels._();

  static const String LEVEL_DEBUG = 'D';
  static const String LEVEL_INFO = 'I';
  static const String LEVEL_WARNING = 'W';
  static const String LEVEL_ERROR = 'E';
  static const String LEVEL_VERBOSE = 'V';

  static const List<String> ALL = <String>[
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARNING,
    LEVEL_ERROR,
    LEVEL_VERBOSE
  ];
}
