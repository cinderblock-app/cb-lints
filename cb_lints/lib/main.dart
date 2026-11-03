import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:cb_lints/src/add_ignore_no_connection.dart';
import 'package:cb_lints/src/api_class_in_presentation.dart';
import 'package:cb_lints/src/connectivity_event_outside_app_epics.dart';
import 'package:cb_lints/src/platform_check_outside_platform_support.dart';
import 'package:cb_lints/src/reader_without_ignore_no_connection.dart';
import 'package:cb_lints/src/route_page_outside_pages.dart';

/// The entry point the analysis server looks up when the app's
/// analysis_options.yaml enables this plugin.
final plugin = CbLintsPlugin();

class CbLintsPlugin extends Plugin {
  @override
  String get name => 'cb_lints';

  @override
  void register(PluginRegistry registry) {
    // A warning rule is on by default; a lint rule would need enabling in
    // analysis_options.yaml.
    registry.registerWarningRule(ApiClassInPresentation());
    registry.registerWarningRule(ConnectivityEventOutsideAppEpics());
    registry.registerWarningRule(PlatformCheckOutsidePlatformSupport());
    registry.registerWarningRule(ReaderWithoutIgnoreNoConnection());
    registry.registerFixForRule(ReaderWithoutIgnoreNoConnection.code, AddIgnoreNoConnection.new);
    registry.registerWarningRule(RoutePageOutsidePages());
  }
}
