import 'package:flutter_test/flutter_test.dart';

import 'package:sunday_selfie/main.dart';

void main() {
  test('solo acepta reacciones disponibles en Sunday Selfie', () {
    expect(normalizarEmojiReaccion('🔥'), '🔥');
    expect(normalizarEmojiReaccion('🔥 texto extra'), '🔥');
    expect(normalizarEmojiReaccion('texto'), isEmpty);
  });

  test('calcula correctamente una semana ISO conocida', () {
    final date = DateTime(2026, 1, 1);

    expect(calcularAnioISO(date), 2026);
    expect(calcularNumeroSemanaISO(date), 1);
  });
}
