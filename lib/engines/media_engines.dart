// Interfaces for future media engines. Not implemented yet: the UI shows
// "Coming Soon" and no inference runs.

abstract interface class ImageEngine {
  String get status;
}

abstract interface class VideoEngine {
  String get status;
}

class ComingSoonImageEngine implements ImageEngine {
  const ComingSoonImageEngine();

  @override
  String get status => 'Coming Soon';
}

class ComingSoonVideoEngine implements VideoEngine {
  const ComingSoonVideoEngine();

  @override
  String get status => 'Coming Soon';
}
