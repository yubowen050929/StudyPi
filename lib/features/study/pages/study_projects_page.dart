import 'package:flutter/material.dart';

import 'package:Kelivo/features/study/pages/study_projects_desktop_layout.dart';
import 'package:Kelivo/features/study/pages/study_projects_mobile_layout.dart';
import 'package:Kelivo/features/workspace/workspace_layout.dart';

export 'package:Kelivo/features/study/pages/study_projects_desktop_layout.dart';
export 'package:Kelivo/features/study/pages/study_projects_mobile_layout.dart';

class StudyProjectsPage extends StatelessWidget {
  const StudyProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (useDesktopWorkspaceLayout(context)) {
      return const StudyProjectsDesktopLayout();
    }
    return const StudyProjectsMobileLayout();
  }
}

Future<void> openStudyProjectsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const StudyProjectsPage()),
  );
}
