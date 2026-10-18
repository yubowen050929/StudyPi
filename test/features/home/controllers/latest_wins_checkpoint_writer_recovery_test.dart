import 'package:Kelivo/features/home/controllers/latest_wins_checkpoint_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final failBuilder in [false, true]) {
    test(
      'recovers after a synchronous ${failBuilder ? 'builder' : 'write'} error',
      () async {
        final writes = <int>[];
        final errors = <Object>[];
        final writer = LatestWinsCheckpointWriter<int>(
          minimumInterval: Duration.zero,
          write: (value) {
            if (!failBuilder && value == 1) {
              throw StateError('synchronous write failure');
            }
            writes.add(value);
            return Future<void>.value();
          },
          onError: (error, _) => errors.add(error),
        );

        writer.add(() {
          if (failBuilder) throw StateError('snapshot build failure');
          return 1;
        });
        await writer.barrier();
        expect(errors, hasLength(1));

        writer.add(() => 2);
        await writer.barrier();
        expect(writes, [2]);
        expect(errors, hasLength(1));

        await writer.finalize(() async => writes.add(3));
        expect(writes, [2, 3]);
        expect(() => writer.add(() => 4), throwsStateError);
      },
    );
  }
}
