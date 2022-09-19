
import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as path;
import 'package:window_size/window_size.dart';

const String VERSION = '1.1.0';

void main() async {

  // おまじない
  WidgetsFlutterBinding.ensureInitialized();

  // ローカライゼーションの初期化
  await EasyLocalization.ensureInitialized();

  // スクリーン情報を取得
  var screen = await getCurrentScreen();

  // スクリーンの DPI スケールを取得
  var dpiScale = screen!.scaleFactor;

  // macOS では DPI スケールに関わらず常に1倍で表示する
  // Windows と DPI スケール周りの扱いが違うのかも…？ 1倍でちょうど良いサイズになる
  if (Platform.isMacOS) {
    dpiScale = 1;
  }

  // ウインドウの最小サイズ
  // DPI スケールに合わせて調整する (Windows のみ)
  /// macOS のみ、ウインドウの最小高さから 10px ほど引く
  /// Windows と macOS でウインドウのタイトルバーの高さが異なるため
  double minWidth = 750 * dpiScale;
  double minHeight = (Platform.isMacOS ? 636 : 646) * dpiScale;

  // 左上を起点にしたウインドウのX座標・Y座標
  double top = (screen.visibleFrame.height - minHeight) / 2;
  double left = (screen.visibleFrame.width - minWidth) / 2;

  // ウインドウの位置とサイズを設定
  setWindowFrame(Rect.fromLTWH(left, top, minWidth, minHeight));

  // 最小ウインドウサイズを設定
  // ref: https://zenn.dev/tris/articles/006c41f9c473a4
  setWindowMinSize(Size(minWidth, minHeight));

  // ウィンドウのタイトルを設定
  setWindowTitle('Real-ESRGAN-GUI');

  // ローカライゼーションを有効化した状態でアプリを起動
  runApp(EasyLocalization(
    path: 'assets/translations',
    supportedLocales: const [
      Locale('en', 'US'),
      Locale('ja', 'JP'),
      Locale('uk'),
    ],
    fallbackLocale: const Locale('en', 'US'),
    child: const RealESRGanGUIApp(),
  ));
}

class RealESRGanGUIApp extends StatelessWidget {
  const RealESRGanGUIApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Real-ESRGAN-GUI',
      theme: ThemeData(
        primarySwatch: Colors.green,
        fontFamily: 'M PLUS 2',
        snackBarTheme: const SnackBarThemeData(
          contentTextStyle: TextStyle(fontFamily: 'M PLUS 2'),
        ),
      ),
      home: const MainWindowPage(title: 'Real-ESRGAN-GUI'),
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
    );
  }
}

class MainWindowPage extends StatefulWidget {
  const MainWindowPage({super.key, required this.title});

  final String title;

  @override
  State<MainWindowPage> createState() => _MainWindowPageState();
}

class _MainWindowPageState extends State<MainWindowPage> with SingleTickerProviderStateMixin {

  // ファイル or フォルダを切り替えるタブのコントローラー
  late TabController fileOrFolderTabController;

  // ***** ファイル選択モード *****

  /// 拡大元の画像ファイル
  XFile? inputFile;

  /// 拡大元の画像ファイルフォームのコントローラー
  TextEditingController inputFileController = TextEditingController();

  /// 保存先の画像ファイルフォームのコントローラー
  TextEditingController outputFileController = TextEditingController();

  // ***** フォルダ選択モード *****

  /// 拡大元の画像フォルダのパス
  String? inputFolderPath;

  /// 拡大元の画像の入ったフォルダフォームのコントローラー
  TextEditingController inputFolderController = TextEditingController();

  /// 保存先のフォルダフォームのコントローラー
  TextEditingController outputFolderController = TextEditingController();

  // ***** 出力設定 *****

  /// モデルの種類 (デフォルト: realesr-animevideov3)
  /// "realesr-animevideov3"・"realesrgan-x4plus-anime"・"realesrgan-x4plus" のいずれか
  String modelType = 'realesr-animevideov3';

  /// 拡大率 (デフォルト: 4倍)
  /// "4x"・"3x"・"2x" のいずれか
  String upscaleRatio = '4x';

  /// 保存形式 (デフォルト: jpg (ただし拡大元の画像ファイルの形式に合わせられる))
  /// "jpg"・"png"・"webp" のいずれか
  String outputFormat = 'jpg';

  // ***** プロセス実行関連 *****

  /// 拡大の進捗状況 (デフォルト: 0%)
  double progress = 0;

  /// 拡大処理を実行中かどうか
  bool isProcessing = false;

  /// コマンドの実行プロセス
  late Process process;

  @override
  void initState() {
    super.initState();

    // TabController を初期化し、タブが変更されたときのイベントを定義
    fileOrFolderTabController = TabController(length: 2, vsync: this);
    fileOrFolderTabController.addListener((){
      if (fileOrFolderTabController.index == 0) {
        // ファイル選択タブに変更されたとき、フォルダ選択タブのフォームをリセットする
        inputFolderPath = null;
        inputFolderController.text = '';
        outputFolderController.text = '';
      } else if (fileOrFolderTabController.index == 1) {
        // フォルダ選択タブに変更されたとき、ファイル選択タブのフォームをリセットする
        inputFile = null;
        inputFileController.text = '';
        outputFileController.text = '';
      }
    });
  }

  /// 保存先のファイル/フォルダパスを更新する
  void updateOutputName() {

    // ファイル選択モード & 拡大元の画像ファイルが選択されている
    if (fileOrFolderTabController.index == 0 && inputFile != null) {

      // 保存形式が拡大元の画像ファイルと同じなら、拡張子には拡大元の画像ファイルと同じものを使う
      var extension = outputFormat;
      if (extension == path.extension(inputFile!.path).toLowerCase().replaceAll('jpeg', 'jpg').replaceAll('.', '')) {
        extension = path.extension(inputFile!.path).replaceAll('.', '');
      }

      // 保存先のファイルパスを (入力画像のファイル名)-upscale-4x.jpg みたいなのに設定
      // 4x の部分は拡大率によって変わる
      // jpg の部分は保存形式によって変わる
      outputFileController.text = '${path.withoutExtension(inputFile!.path)}-upscale-${upscaleRatio}.${extension}';

    // フォルダ選択モード & 拡大元の画像フォルダが選択されている
    } else if (fileOrFolderTabController.index == 1 && inputFolderPath != null) {

      // 保存先のフォルダパスを (入力画像のフォルダ名)-upscale-4x みたいなのに設定
      // 4x の部分は拡大率によって変わる
      // jpg の部分は保存形式によって変わる
      outputFolderController.text = '${inputFolderPath}-upscale-${upscaleRatio}';
    }
  }

  /// 画像の拡大処理を開始する
  Future<void> upscaleImage() async {

    // 既に拡大処理を実行中のときは拡大処理をキャンセルする
    if (isProcessing == true) {
      process.kill();
      isProcessing = false;
      return;
    }

    // バリデーション (ファイル選択モード)
    if (fileOrFolderTabController.index == 0) {

      // 入力元ファイルが指定されていない
      if (inputFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('message.noInputFile').tr(),
          action: SnackBarAction(
            label: 'label.close'.tr(),
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ));
        return;
      }

      // 出力先ファイルが指定されていない
      if (outputFileController.text == '') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('message.noOutputFilePath').tr(),
          action: SnackBarAction(
            label: 'label.close'.tr(),
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ));
        return;
      }

      // 出力先ファイルが既に存在する場合
      // 上書きするかの確認を取る
      if (await File(outputFileController.text).exists()) {
        var overwrite = false;
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) {
            return AlertDialog(
              title: const Text('label.overwriteConfirm').tr(),
              content: const Text('message.overwriteFileConfirm').tr(args: [outputFileController.text]),
              actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
              actions: [
                TextButton(
                  child: const Text('label.cancel').tr(),
                  onPressed: () => Navigator.pop(context),
                ),
                TextButton(
                  child: const Text('label.overwriteFile').tr(),
                  onPressed: () {
                    overwrite = true;
                    Navigator.pop(context);
                  }
                ),
              ],
            );
          },
        );
        // キャンセルされたら実行しない
        if (overwrite == false) return;
      }

    // バリデーション (フォルダ選択モード)
    } else if (fileOrFolderTabController.index == 1) {

      // 入力元フォルダが指定されていない
      if (inputFolderPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('message.noInputFolder').tr(),
          action: SnackBarAction(
            label: 'label.close'.tr(),
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ));
        return;
      }

      // 出力先ファイルが指定されていない
      if (outputFolderController.text == '') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('message.noOutputFolderPath').tr(),
          action: SnackBarAction(
            label: 'label.close'.tr(),
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ));
        return;
      }

      // 出力先フォルダが既に存在する場合
      // 上書きするかの確認を取る
      if (await Directory(outputFolderController.text).exists()) {
        var overwrite = false;
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) {
            return AlertDialog(
              title: const Text('label.overwriteConfirm').tr(),
              content: const Text('message.overwriteFolderConfirm').tr(args: [outputFolderController.text]),
              actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
              actions: [
                TextButton(
                  child: const Text('label.cancel').tr(),
                  onPressed: () => Navigator.pop(context),
                ),
                TextButton(
                  child: const Text('label.overwriteFolder').tr(),
                  onPressed: () {
                    overwrite = true;
                    Navigator.pop(context);
                  }
                ),
              ],
            );
          },
        );
        // キャンセルされたら実行しない
        if (overwrite == false) return;
      }
    }

    // 処理対象の画像ファイルのパスのリスト
    List<Map<String, String>> imageFiles = [];

    // ファイル選択モードでは、選択されたファイル1つだけを追加する
    if (fileOrFolderTabController.index == 0) {

      // 入力元ファイルと出力先ファイルをセットで追加
      // 出力先ファイルにはフォームの値を使う
      imageFiles.add({'input': inputFile!.path, 'output': outputFileController.text});

      // 出力先ファイルが保存されるフォルダを作成 (すでにある場合は何もしない)
      await Directory(path.dirname(outputFileController.text)).create(recursive: true);

    // フォルダ選択モードでは、選択されたフォルダ以下の画像ファイル（1階層のみ）すべてを追加する
    } else if (fileOrFolderTabController.index == 1) {

      // 画像ファイルのみを Glob で取得
      var glob = Glob('{*.jpg,*.jpeg,*.png,*.webp}');
      for (var file in glob.listSync(root: inputFolderPath)) {

        // 出力先ファイル名を生成
        var outputFilePath = path.join(
          // 出力先フォルダフォームの値
          outputFolderController.text,
          // 入力元ファイルの拡張子なしファイル名 + 保存形式 (jpg / png / webp)
          '${path.basenameWithoutExtension(file.path)}.${outputFormat}',
        );

        // 入力元ファイルと出力先ファイルをセットで追加
        imageFiles.add({'input': file.path, 'output': outputFilePath});
      }

      // この時点でひとつも画像ファイルが見つからなかった場合、エラーを出して終了
      if (imageFiles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('message.noImageFilesInFolder').tr(),
          action: SnackBarAction(
            label: 'label.close'.tr(),
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ));
        return;
      }

      // 出力先フォルダを作成 (すでにある場合は何もしない)
      await Directory(outputFolderController.text).create(recursive: true);
    }

    // プログレスバーを一旦 0% に戻す
    setState(() {
      progress = 0;
      isProcessing = true;
    });

    // 画像ファイル1つごとに何%プログレスバーを進めるかの値
    // たとえば4つのファイルが処理対象なら、ここには 25 (%) が入る
    var progressStep = 100 / imageFiles.length;

    // 画像ファイルごとに繰り返す
    for (var progressIndex = 0; progressIndex < imageFiles.length; progressIndex++) {

      // realesrgan-ncnn-vulkan の実行ファイルのパスを取得
      String executablePath = '';
      if (Platform.isWindows) {
        // Windows: Real-ESRGAN-GUI/data/flutter_assets/assets/realesrgan-ncnn-vulkan.exe
        executablePath = path.join(
          path.dirname(Platform.resolvedExecutable),
          'data/flutter_assets/assets/realesrgan-ncnn-vulkan.exe',
        );
      } else if (Platform.isMacOS) {
        // macOS: Real-ESRGAN-GUI.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/realesrgan-ncnn-vulkan
        executablePath = path.join(
          path.dirname(Platform.resolvedExecutable).replaceAll('MacOS', ''),
          'Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/realesrgan-ncnn-vulkan',
        );
      }

      // realesrgan-ncnn-vulkan コマンドを実行
      // ワーキングディレクトリを実行ファイルと同じフォルダに移動しておかないと macOS で Segmentation fault になり実行に失敗する
      // 実行ファイルと同じフォルダでないと models/ 以下の学習済みモデルが読み込めないのかも…？
      // ref: https://api.dart.dev/stable/2.18.0/dart-io/Process-class.html
      process = await Process.start(executablePath,
        [
          // 拡大元の画像ファイル
          '-i', imageFiles[progressIndex]['input']!,
          // 保存先の画像ファイル
          '-o', imageFiles[progressIndex]['output']!,
          // 利用モデル
          '-n', modelType,
          // 拡大率 (4x の x は除く)
          '-s', upscaleRatio.replaceAll('x', ''),
          // 保存形式
          '-f', outputFormat,
        ],
        workingDirectory: path.dirname(executablePath),
      );

      // 標準エラー出力を受け取ったとき
      List<String> lines = [];  // すべてのログを貯めるリスト
      process.stderr.transform(utf8.decoder).forEach((line) {

        // 22.00% みたいな進捗ログの取得を試みる
        var progressMatch = RegExp(r'([0-9]+\.[0-9]+)%').firstMatch(line);

        // プログレスバーを更新 (進捗ログを取得できたときのみ)
        if (progressMatch != null) {

          // 進捗ログを数値としてパースして格納
          var progressData = double.parse(progressMatch.group(1) ?? '0');

          setState(() {
            // 完了済みの画像の進捗 + 現在処理中の画像の進捗
            progress = (progressStep * (progressIndex)) + (progressData / imageFiles.length);
          });

        // 失敗したときにエラーログを表示するために受け取ったログを貯めておく
        } else {
          lines.add(line);
        }
      });

      // realesrgan-ncnn-vulkan の終了を待つ
      var exitCode = await process.exitCode;

      // プロセス終了のこの時点で isProcessing が false になっている場合、以降の処理がキャンセルされたものとして扱う
      var isCanceled = false;
      if (isProcessing == false) isCanceled = true;

      // プログレスバーを (progressStep × 完了済みの画像の個数) に設定
      setState(() {
        progress = progressStep * (progressIndex + 1);
      });

      // 終了コードが 0 以外 (エラーで失敗)
      if (exitCode != 0) {

        // キャンセルの場合のメッセージ
        if (isCanceled) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('message.canceled').tr(),
            action: SnackBarAction(
              label: 'label.close'.tr(),
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
            ),
          ));
        // エラーの場合のメッセージ
        } else {

          // 実行ログを取得し、文字列として連結
          // もじ実行ログが空のときは、代わりに終了コードを入れる
          var log = lines.join('').trim();
          if (log == '') log = 'exit code: ${exitCode}';

          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: SingleChildScrollView(
              child: Column(
                children: [
                  const Text('message.failed').tr(),
                  const Text('message.errorLog').tr(args: [log]),
                ],
              ),
            ),
            duration: const Duration(seconds: 10),  // 10秒間表示
            action: SnackBarAction(
              label: 'label.close'.tr(),
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
            ),
          ));
        }

        // プログレスバーを 0% に戻す
        setState(() {
          progress = 0;
          isProcessing = false;
        });

        // 実行を中断
        return;
      }
    }

    // 完了した旨を表示する
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('message.completed').tr(),
      action: SnackBarAction(
        label: 'label.close'.tr(),
        onPressed: () {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        },
      ),
    ));

    // プログレスバーを 0% に戻す
    setState(() {
      progress = 0;
      isProcessing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: const [
          Center(
            child: Text('version ${VERSION}', style: TextStyle(fontSize: 16)),
          ),
          SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, left: 24, right: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: <Widget>[
                TabBar(
                  controller: fileOrFolderTabController,
                  tabs: const [
                    Tab(child: Text('ファイル選択', style: TextStyle(color: Colors.green, fontSize: 16))),
                    Tab(child: Text('フォルダ選択（一括処理）', style: TextStyle(color: Colors.green, fontSize: 16))),
                  ],
                ),
                SizedBox(
                  height: 158,
                  child: TabBarView(
                    controller: fileOrFolderTabController,
                    children: [
                      Column(
                        children: [
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              // Expanded で挟まないとエラーになる
                              Expanded(
                                child: TextField(
                                  readOnly: true,
                                  controller: inputFileController,
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    labelText: 'label.inputFile'.tr(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              SizedBox(
                                height: 52,
                                child: ElevatedButton.icon(
                                  // ファイル選択ボタンが押されたとき
                                  onPressed: () async {

                                    // 選択を許可する拡張子の一覧
                                    final imageTypeGroup = XTypeGroup(
                                      label: 'images',
                                      extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
                                    );

                                    // ファイルピッカーを開き、選択されたファイルを格納
                                    inputFile = await openFile(acceptedTypeGroups: <XTypeGroup>[imageTypeGroup]);

                                    // もし拡大元の画像ファイルが入っていれば、フォームにファイルパスを設定
                                    if (inputFile != null) {
                                      setState(() {

                                        // 拡大元の画像ファイルフォームのテキストを更新
                                        inputFileController.text = inputFile!.path;

                                        // 保存形式を拡大元の画像ファイルの拡張子から取得
                                        // 拡張子が .jpeg だった場合も jpg に統一する
                                        outputFormat = path.extension(inputFile!.path).replaceAll('.', '').toLowerCase();
                                        if (outputFormat == 'jpeg') outputFormat = 'jpg';

                                        // 保存先の画像ファイルフォームのテキストを更新
                                        updateOutputName();
                                      });

                                    // フォルダ選択がキャンセルされたので、フォームをリセット
                                    } else {
                                      inputFileController.text = '';
                                      outputFileController.text = '';
                                    }
                                  },
                                  icon: const Icon(Icons.file_open_rounded),
                                  label: Text('label.imageSelect'.tr(), style: const TextStyle(fontSize: 16, height: 1.3)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: outputFileController,
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              labelText: 'label.outputFilePath'.tr(),
                            ),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              // Expanded で挟まないとエラーになる
                              Expanded(
                                child: TextField(
                                  readOnly: true,
                                  controller: inputFolderController,
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    labelText: 'label.inputFolder'.tr(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              SizedBox(
                                height: 52,
                                child: ElevatedButton.icon(
                                  // フォルダ選択ボタンが押されたとき
                                  onPressed: () async {

                                    // フォルダピッカーを開き、選択されたフォルダのパスを格納
                                    inputFolderPath = await FilePicker.platform.getDirectoryPath(dialogTitle: '開く');

                                    // もし拡大元の画像フォルダのパスが入っていれば、フォームにフォルダパスを設定
                                    if (inputFolderPath != null) {
                                      setState(() {

                                        // 拡大元の画像フォルダフォームのテキストを更新
                                        inputFolderController.text = inputFolderPath!;

                                        // 保存先の画像フォルダフォームのテキストを更新
                                        updateOutputName();
                                      });

                                    // フォルダ選択がキャンセルされたので、フォームをリセット
                                    } else {
                                      inputFolderController.text = '';
                                      outputFolderController.text = '';
                                    }
                                  },
                                  icon: const Icon(Icons.snippet_folder_rounded),
                                  label: Text('label.folderSelect'.tr(), style: const TextStyle(fontSize: 16, height: 1.3)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: outputFolderController,
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              labelText: 'label.outputFolderPath'.tr(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text('label.model'.tr(), style: const TextStyle(fontSize: 16)),
                    ),
                    Expanded(
                      child: DropdownButtonFormField(
                        decoration: const InputDecoration(border: OutlineInputBorder()),
                        value: modelType,
                        items: [
                          DropdownMenuItem(
                            value: 'realesr-animevideov3',
                            child: const Text('model.animevideov3').tr(),
                          ),
                          DropdownMenuItem(
                            value: 'realesrgan-x4plus-anime',
                            child: const Text('model.x4plus-anime').tr(),
                          ),
                          DropdownMenuItem(
                            value: 'realesrgan-x4plus',
                            child: const Text('model.x4plus').tr(),
                          ),
                        ],
                        onChanged: (String? value) {
                          setState(() {
                            // 利用モデルが変更されたらセット
                            modelType = value ?? 'realesr-animevideov3';
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text('label.scale'.tr(), style: const TextStyle(fontSize: 16)),
                    ),
                    Expanded(
                      child: DropdownButtonFormField(
                        decoration: const InputDecoration(border: OutlineInputBorder()),
                        value: upscaleRatio,
                        items: [
                          DropdownMenuItem(
                            value: '4x',
                            child: const Text('scale.4x').tr(),
                          ),
                          DropdownMenuItem(
                            value: '3x',
                            child: const Text('scale.3x').tr(),
                          ),
                          DropdownMenuItem(
                            value: '2x',
                            child: const Text('scale.2x').tr(),
                          ),
                        ],
                        onChanged: (String? value) {
                          setState(() {
                            // 拡大率が変更されたらセット
                            upscaleRatio = value ?? '4x';

                            // 保存先の画像ファイル or フォルダフォームのテキストを更新
                            updateOutputName();
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text('label.format'.tr(), style: const TextStyle(fontSize: 16)),
                    ),
                    Expanded(
                      child: DropdownButtonFormField(
                        decoration: const InputDecoration(border: OutlineInputBorder()),
                        value: outputFormat,
                        items: [
                          DropdownMenuItem(
                            value: 'jpg',
                            child: const Text('format.jpeg').tr(),
                          ),
                          DropdownMenuItem(
                            value: 'png',
                            child: const Text('format.png').tr(),
                          ),
                          DropdownMenuItem(
                            value: 'webp',
                            child: const Text('format.webp').tr(),
                          ),
                        ],
                        onChanged: (String? value) {
                          setState(() {
                            // 保存形式が変更されたらセット
                            outputFormat = value ?? 'jpg';

                            // 保存先の画像ファイル or フォルダフォームのテキストを更新
                            updateOutputName();
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
          const Spacer(),
          Column(
            children: [
              Center(
                child: SizedBox(
                  width: 208,
                  height: 54,
                  child: ElevatedButton.icon(
                    // 拡大開始ボタンが押されたとき
                    onPressed: upscaleImage,
                    icon: Icon(isProcessing ? Icons.cancel : Icons.image_rounded),
                    label: Text(isProcessing ? 'label.cancel'.tr() : 'label.start'.tr(), style: const TextStyle(fontSize: 20, height: 1.3)),
                    style: ButtonStyle(backgroundColor: isProcessing ? MaterialStateProperty.all(const Color(0xFFEE525A)) : null),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: progress / 100,  // 100 で割った (0~1 の範囲) 値を与える
                minHeight: 20,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
