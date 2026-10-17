import 'study/study_prompts.dart';

/// Shared default prompt for the database-backed learning-mode setting and
/// instruction-injection seeding.
class LearningModeStore {
  LearningModeStore._();

  static const String defaultPrompt = StudyPrompts.guidedStudy;
}
