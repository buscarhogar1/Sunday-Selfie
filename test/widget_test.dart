import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sunday_selfie/main.dart';

void main() {
  const englandFlag =
      '🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}';

  test(
    'el reencuadre de un montaje solo se activa si la foto tiene margen',
    () {
      expect(
        montagePhotoCanBeReframed(
          imageSize: const Size(720, 1280),
          frameSize: const Size(180, 180),
        ),
        isTrue,
      );
      expect(
        montagePhotoCanBeReframed(
          imageSize: const Size(720, 720),
          frameSize: const Size(180, 180),
        ),
        isFalse,
      );
    },
  );

  test('el reencuadre se limita a los bordes de la imagen', () {
    final alignment = montagePhotoAlignmentAfterDrag(
      imageSize: const Size(100, 300),
      frameSize: const Size(100, 100),
      startAlignment: Alignment.center,
      offsetFromOrigin: const Offset(0, 500),
    );

    expect(alignment.x, 0);
    expect(alignment.y, -1);
  });

  testWidgets('el cierre de sesión elimina las rutas autenticadas', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Inicio')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Ajustes')),
      ),
    );
    await tester.pumpAndSettle();

    restablecerNavegacionTrasCerrarSesion(navigatorKey.currentState);
    await tester.pumpAndSettle();

    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Ajustes'), findsNothing);
  });

  testWidgets('la miniatura publicada indica que se puede rehacer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: CameraSelfieRetakeThumbnail(thumbnailUrl: '')),
        ),
      ),
    );

    expect(find.text('Rehacer'), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget);
  });

  testWidgets('la miniatura publicada recorta la foto dentro del marco', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CameraSelfieRetakeThumbnail(
              thumbnailUrl: 'https://example.invalid/selfie.jpg',
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('camera-published-selfie-thumbnail-frame')),
      findsOneWidget,
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('camera-published-selfie-thumbnail-frame')),
      ),
      const Size(42, 42),
    );
    expect(
      find.byKey(const ValueKey('camera-published-selfie-thumbnail-clip')),
      findsOneWidget,
    );

    final decoration = tester.widget<DecoratedBox>(
      find.byType(DecoratedBox),
    ).decoration as BoxDecoration;
    expect(decoration.border, isNull);

    final image = tester.widget<CachedRemoteImage>(
      find.byType(CachedRemoteImage),
    );
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('la pantalla de rehacer compacta fecha y se adapta a la altura', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SelfieReplacementInfoScreen(
          selfieImageUrl: '',
          selfieThumbnailUrl: '',
          weekKey: '2026-W35',
          publishedAt: DateTime(2026, 8, 30),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('30 ago'), findsOneWidget);
    expect(find.text('domingo, 30 de agosto'), findsNothing);

    final tallPolaroid = tester.getSize(
      find.byKey(const ValueKey('selfie-replacement-polaroid')),
    );
    final descriptionBottom = tester
        .getBottomLeft(
          find.text('Puedes rehacerla una sola vez viendo un anuncio.'),
        )
        .dy;
    final buttonTextTop = tester.getTopLeft(find.text('Ver anuncio')).dy;
    expect(buttonTextTop - descriptionBottom, lessThan(64));
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(360, 600));
    await tester.pump();

    final compactPolaroid = tester.getSize(
      find.byKey(const ValueKey('selfie-replacement-polaroid')),
    );
    expect(compactPolaroid.height, lessThan(tallPolaroid.height));
    expect(
      tester.getBottomRight(find.text('Conservar mi selfie actual')).dy,
      lessThanOrEqualTo(600),
    );
    expect(tester.takeException(), isNull);
  });

  test('en Cámara prioriza los grupos pendientes de esta semana', () {
    final selfieStatus = {
      'publicado': true,
      'pendiente_b': false,
      'pendiente_a': false,
    };
    final groupIds = selfieStatus.keys.toList();

    groupIds.sort((a, b) {
      final comparison = compareCameraGroupsByCurrentWeekSelfie(
        selfieStatus[a]!,
        selfieStatus[b]!,
      );
      return comparison != 0 ? comparison : a.compareTo(b);
    });

    expect(groupIds, ['pendiente_a', 'pendiente_b', 'publicado']);
  });

  test('traduce todos los textos globales del acceso en cada idioma', () {
    final sourceKeys = kSundayInterfaceTranslations['en']!.keys.toSet();

    for (final languageCode in kSundaySupportedLanguageCodes) {
      if (languageCode == 'es') continue;

      final translations = kSundayInterfaceTranslations[languageCode];
      expect(translations, isNotNull, reason: languageCode);
      expect(translations!.keys.toSet(), sourceKeys, reason: languageCode);

      for (final source in sourceKeys) {
        expect(
          sundayTranslate(source, languageCode: languageCode),
          isNot(source),
          reason: '$languageCode: $source',
        );
      }
    }
  });

  test('solo acepta reacciones con un emoji real', () {
    expect(normalizarEmojiReaccion('🔥'), '🔥');
    expect(normalizarEmojiReaccion('🔥 texto extra'), '🔥');
    expect(normalizarEmojiReaccion('🇪🇸 texto extra'), '🇪🇸');
    expect(normalizarEmojiReaccion('👩‍💻'), '👩‍💻');
    expect(normalizarEmojiReaccion('1️⃣'), '1️⃣');
    expect(normalizarEmojiReaccion(englandFlag), englandFlag);
    expect(normalizarEmojiReaccion('texto'), isEmpty);
    expect(esEmojiReaccion('🔥 texto extra'), isFalse);
  });

  test('incluye un catalogo amplio y valido de reacciones emoji', () {
    expect(kSundayReactionEmojiSections.first.label, 'Todos');
    expect(kSundayReactionEmojiSections.first.emojis, kSundayReactionEmojis);
    expect(kSundayReactionEmojis.length, greaterThan(3900));
    expect(kSundayReactionEmojis.contains('🫨'), isTrue);
    expect(kSundayReactionEmojis.contains('🙂‍↔️'), isTrue);
    expect(kSundayReactionEmojis.contains('👋🏿'), isTrue);
    expect(kSundayReactionEmojis.contains(englandFlag), isTrue);

    for (final emoji in kSundayReactionEmojis) {
      expect(esEmojiReaccion(emoji), isTrue, reason: emoji);
    }
  });

  test('agrupa variantes de tono de piel en una sola opcion', () {
    final groups = agruparEmojisReaccion(['👍', '👍🏻', '👍🏿', '🔥']);
    final thumbGroup = groups.firstWhere((group) => group.key == '👍');

    expect(groups.length, 2);
    expect(thumbGroup.displayEmoji, '👍');
    expect(thumbGroup.variants, ['👍', '👍🏻', '👍🏿']);
  });

  test('agrupa variantes estilo WhatsApp de genero y apariencia', () {
    final groups = agruparEmojisReaccion([
      '🧑‍🍳',
      '🧑🏽‍🍳',
      '👨‍🍳',
      '👨🏻‍🍳',
      '👩🏿‍🍳',
      '🙋',
      '🙋‍♂️',
      '🙋🏽‍♀️',
      '👨‍🦰',
      '👩🏿‍🦰',
      '🧑‍🦰',
      '🔥',
    ]);
    final cookGroup = groups.firstWhere((group) => group.key == '🧑‍🍳');
    final raisingHandGroup = groups.firstWhere((group) => group.key == '🙋');
    final redHairGroup = groups.firstWhere((group) => group.key == '🧑‍🦰');

    expect(groups.length, 4);
    expect(cookGroup.displayEmoji, '🧑‍🍳');
    expect(
      cookGroup.variants,
      containsAll(['🧑‍🍳', '🧑🏽‍🍳', '👨‍🍳', '👨🏻‍🍳', '👩🏿‍🍳']),
    );
    expect(raisingHandGroup.variants, ['🙋', '🙋‍♂️', '🙋🏽‍♀️']);
    expect(redHairGroup.displayEmoji, '🧑‍🦰');
    expect(redHairGroup.variants, containsAll(['👨‍🦰', '👩🏿‍🦰', '🧑‍🦰']));
  });

  test('los grupos pueden usar el catalogo completo de emoji', () {
    expect(kGroupEmojiSections.first.label, 'Todos');
    expect(kGroupEmojiSections.first.emojis, kGroupEmojiOptions);
    expect(kGroupEmojiOptions, kSundayReactionEmojis);
    expect(kGroupEmojiOptions.length, greaterThan(3900));
    expect(kGroupEmojiOptions.contains('👩‍💻'), isTrue);
    expect(kGroupEmojiOptions.contains('🏖️'), isTrue);
    expect(kGroupEmojiOptions.contains(englandFlag), isTrue);

    final groupedEmojiOptions = agruparEmojisReaccion(
      kGroupEmojiSections.first.emojis,
    );
    final wavingGroup = groupedEmojiOptions.firstWhere(
      (group) => group.key == '👋',
    );
    expect(groupedEmojiOptions.length, lessThan(kGroupEmojiOptions.length));
    expect(wavingGroup.variants, containsAll(['👋', '👋🏻', '👋🏿']));
    expect(
      groupedEmojiOptions.firstWhere((group) => group.key == '🧑‍🍳').variants,
      containsAll(['🧑‍🍳', '👨‍🍳', '👩‍🍳']),
    );
  });

  test('calcula correctamente una semana ISO conocida', () {
    final date = DateTime(2026, 1, 1);

    expect(calcularAnioISO(date), 2026);
    expect(calcularNumeroSemanaISO(date), 1);
  });

  test('programa el refresco justo despues de cambiar de dia', () {
    final sundayNight = DateTime(2026, 6, 14, 23, 59, 50);

    expect(
      proximoRefrescoCambioDeDia(sundayNight),
      DateTime(2026, 6, 15, 0, 0, 0, 250),
    );
  });

  test('usa la hora de Madrid para abrir la semana del domingo', () {
    final madridSunday = sundayAppTimeFromUtc(
      DateTime.utc(2026, 8, 15, 22, 11),
    );

    expect(madridSunday, DateTime(2026, 8, 16, 0, 11));
    expect(esDomingo(now: madridSunday), isTrue);
    expect(obtenerWeekKeyActual(now: madridSunday), '2026-W33');
    expect(obtenerWeekKeyVisibleMasReciente(now: madridSunday), '2026-W33');
  });

  test('programa el refresco segun el cambio de dia en Madrid', () {
    final delay = demoraHastaProximoRefrescoCambioDeDia(
      utcNow: DateTime.utc(2026, 8, 15, 22, 11),
    );

    expect(delay, const Duration(hours: 23, minutes: 49, milliseconds: 250));
  });

  test('limita los pixeles exportados en montajes largos', () {
    expect(
      calcularPixelRatioCapturaMontaje(const Size(360, 900)),
      kMontageCaptureMaxPixelRatio,
    );

    final longRatio = calcularPixelRatioCapturaMontaje(const Size(390, 18000));
    expect(longRatio, lessThan(kMontageCaptureMaxPixelRatio));
    expect(longRatio, greaterThanOrEqualTo(kMontageCaptureMinPixelRatio));
  });

  test('oculta la semana actual cuando todavia no es domingo', () {
    final now = DateTime(2026, 6, 11);
    final currentWeekKey = obtenerWeekKeyActual(now: now);
    final previousWeekKey = obtenerWeekKeyAnterior(currentWeekKey);
    final olderWeekKey = obtenerWeekKeyAnterior(previousWeekKey);
    final visibleWeekKeys = obtenerWeekKeysDomingosVisibles([
      currentWeekKey,
      previousWeekKey,
      '9999-W01',
      olderWeekKey,
    ], now: now);

    expect(visibleWeekKeys, [previousWeekKey, olderWeekKey]);
  });

  test('incluye el domingo actual si hoy es domingo', () {
    final now = DateTime(2026, 6, 14);
    final currentWeekKey = obtenerWeekKeyActual(now: now);
    final previousWeekKey = obtenerWeekKeyAnterior(currentWeekKey);
    final visibleWeekKeys = obtenerWeekKeysDomingosVisibles([
      currentWeekKey,
      previousWeekKey,
      currentWeekKey,
    ], now: now);

    expect(visibleWeekKeys, [currentWeekKey, previousWeekKey]);
  });

  test('permite subir el lunes solo para la semana anterior', () {
    final monday = DateTime(2026, 6, 15, 10);
    final currentWeekKey = obtenerWeekKeyActual(now: monday);
    final previousWeekKey = obtenerWeekKeyAnterior(currentWeekKey);

    expect(
      puedeSubirSelfieLunesConRetraso(previousWeekKey, now: monday),
      isTrue,
    );
    expect(
      puedeSubirSelfieLunesConRetraso(currentWeekKey, now: monday),
      isFalse,
    );
    expect(
      puedeSubirSelfieLunesConRetraso(
        previousWeekKey,
        now: DateTime(2026, 6, 16, 10),
      ),
      isFalse,
    );
  });

  test(
    'permite usar una selfie como foto de perfil solo domingo o lunes posterior',
    () {
      final sunday = DateTime(2026, 6, 28, 10);
      final sundayWeekKey = obtenerWeekKeyActual(now: sunday);
      final previousWeekKey = obtenerWeekKeyAnterior(sundayWeekKey);
      final monday = DateTime(2026, 6, 29, 10);
      final saturday = DateTime(2026, 7, 4, 10);

      expect(puedeUsarSelfieComoFotoPerfil(sundayWeekKey, now: sunday), isTrue);
      expect(
        puedeUsarSelfieComoFotoPerfil(previousWeekKey, now: sunday),
        isFalse,
      );
      expect(puedeUsarSelfieComoFotoPerfil(sundayWeekKey, now: monday), isTrue);
      expect(
        puedeUsarSelfieComoFotoPerfil(
          obtenerWeekKeyActual(now: monday),
          now: monday,
        ),
        isFalse,
      );
      expect(
        puedeUsarSelfieComoFotoPerfil(sundayWeekKey, now: saturday),
        isFalse,
      );
    },
  );

  test('etiqueta como pendiente solo domingo actual o lunes posterior', () {
    final sunday = DateTime(2026, 6, 14, 10);
    final sundayWeekKey = obtenerWeekKeyActual(now: sunday);
    final previousWeekKey = obtenerWeekKeyAnterior(sundayWeekKey);
    final monday = DateTime(2026, 6, 15, 10);
    final tuesday = DateTime(2026, 6, 16, 10);

    expect(
      missingSundaySelfieStatusLabel(sundayWeekKey, now: sunday),
      'Sunday Selfie pendiente',
    );
    expect(
      missingSundaySelfieStatusLabel(previousWeekKey, now: sunday),
      'Sunday Selfie no publicado',
    );
    expect(
      missingSundaySelfieStatusLabel(sundayWeekKey, now: monday),
      'Sunday Selfie pendiente',
    );
    expect(
      missingSundaySelfieStatusLabel(sundayWeekKey, now: tuesday),
      'Sunday Selfie no publicado',
    );
  });

  test('estado de miembro sin publicar solo aparece en domingo', () {
    final sunday = DateTime(2026, 6, 14, 10);
    final monday = DateTime(2026, 6, 15, 10);

    expect(debeMostrarMiembroSinPublicar(posted: false, now: sunday), isTrue);
    expect(debeMostrarMiembroSinPublicar(posted: false, now: monday), isFalse);
    expect(debeMostrarMiembroSinPublicar(posted: true, now: sunday), isFalse);
  });

  test('muestra la semana anterior el lunes aunque no haya publicaciones', () {
    final monday = DateTime(2026, 6, 15, 10);
    final previousWeekKey = obtenerWeekKeyDomingoAnterior(now: monday);

    expect(obtenerWeekKeysDomingosVisibles([], now: monday), [previousWeekKey]);
  });

  test(
    'muestra la semana visible mas reciente entre semana sin publicaciones',
    () {
      final thursday = DateTime(2026, 6, 11, 10);
      final latestVisibleWeekKey = obtenerWeekKeyVisibleMasReciente(
        now: thursday,
      );

      expect(obtenerWeekKeysDomingosVisibles([], now: thursday), [
        latestVisibleWeekKey,
      ]);
    },
  );

  test('la racha empieza en la ultima semana visible', () {
    final monday = DateTime(2026, 6, 15, 10);
    final sunday = DateTime(2026, 6, 14, 10);

    expect(
      obtenerWeekKeyInicioRachaPublicacion(now: monday),
      obtenerWeekKeyDomingoAnterior(now: monday),
    );
    expect(
      obtenerWeekKeyInicioRachaPublicacion(now: sunday),
      obtenerWeekKeyActual(now: sunday),
    );
  });

  test('el calendario del grupo empieza en la semana de creacion', () {
    final now = DateTime(2026, 6, 11);
    final weekKeys = obtenerWeekKeysCalendarioGrupo(
      groupCreatedAt: DateTime(2026, 5, 20),
      existingWeekKeys: ['2026-W01'],
      now: now,
    );

    expect(weekKeys, ['2026-W23', '2026-W22', '2026-W21']);
  });

  test('la semana inicial del grupo es la mas reciente visible', () {
    final now = DateTime(2026, 6, 11, 10);
    final currentWeekKey = obtenerWeekKeyActual(now: now);
    final latestVisibleWeekKey = obtenerWeekKeyVisibleMasReciente(now: now);
    final olderWeekKey = obtenerWeekKeyAnterior(latestVisibleWeekKey);

    expect(
      resolverWeekKeySeleccionadaGrupo(
        weekKeys: [currentWeekKey, latestVisibleWeekKey, olderWeekKey],
        selectedWeekKey: '',
        now: now,
      ),
      latestVisibleWeekKey,
    );
    expect(
      resolverWeekKeySeleccionadaGrupo(
        weekKeys: [latestVisibleWeekKey, olderWeekKey],
        selectedWeekKey: olderWeekKey,
        now: now,
      ),
      olderWeekKey,
    );
  });

  test('la semana inicial del grupo en domingo es el domingo actual', () {
    final sunday = DateTime(2026, 6, 14, 10);
    final currentWeekKey = obtenerWeekKeyActual(now: sunday);
    final previousWeekKey = obtenerWeekKeyAnterior(currentWeekKey);

    expect(
      resolverWeekKeySeleccionadaGrupo(
        weekKeys: [currentWeekKey, previousWeekKey],
        selectedWeekKey: '',
        now: sunday,
      ),
      currentWeekKey,
    );
  });

  test('ordena todos los selfies del grupo desde el mas reciente', () {
    final entries = [
      GroupPublishedSelfieEntry(
        weekKey: '2026-W22',
        postUid: 'ana',
        post: {'updatedAt': DateTime(2026, 5, 31, 21)},
      ),
      GroupPublishedSelfieEntry(
        weekKey: '2026-W24',
        postUid: 'bea',
        post: {'createdAt': DateTime(2026, 6, 14, 20)},
      ),
      GroupPublishedSelfieEntry(
        weekKey: '2026-W23',
        postUid: 'carlos',
        post: {'updatedAt': DateTime(2026, 6, 7, 19)},
      ),
    ];

    entries.sort(compareGroupPublishedSelfiesNewest);

    expect(entries.map((entry) => entry.postUid), ['bea', 'carlos', 'ana']);
  });

  test('ordena grupos por actividad de selfie o chat', () {
    final groups = <Map<String, dynamic>>[
      {
        'id': 'actividad_general_reciente',
        'lastActivityAt': DateTime(2026, 7, 4, 12),
        'joinedAt': DateTime(2026, 2, 1),
      },
      {'id': 'sin_contenido_reciente', 'joinedAt': DateTime(2026, 7, 1)},
      {
        'id': 'selfie_o_chat_antiguo',
        'lastSelfieOrChatActivityAt': DateTime(2026, 6, 12, 18),
        'joinedAt': DateTime(2026, 1, 1),
      },
      {
        'id': 'selfie_o_chat_reciente',
        'lastSelfieOrChatActivityAt': DateTime(2026, 6, 14, 20),
        'joinedAt': DateTime(2026, 1, 1),
      },
    ];

    groups.sort(compareUserGroupsBySelfieOrChatActivity);

    expect(groups.map((group) => group['id']), [
      'selfie_o_chat_reciente',
      'selfie_o_chat_antiguo',
      'sin_contenido_reciente',
      'actividad_general_reciente',
    ]);
  });

  test('la racha completa del grupo calcula actual y record', () {
    final stats = calcularEstadisticasRachaCompletaGrupo(
      weekKeys: const [
        '2026-W24',
        '2026-W23',
        '2026-W22',
        '2026-W21',
        '2026-W20',
        '2026-W19',
      ],
      postCountsByWeek: const {
        '2026-W24': 3,
        '2026-W23': 3,
        '2026-W22': 2,
        '2026-W21': 3,
        '2026-W20': 3,
        '2026-W19': 3,
      },
      memberCount: 3,
    );

    expect(stats.current, 2);
    expect(stats.record, 3);
  });

  test('la racha completa del grupo se corta si falta una selfie', () {
    final stats = calcularEstadisticasRachaCompletaGrupo(
      weekKeys: const ['2026-W24', '2026-W23', '2026-W22'],
      postCountsByWeek: const {'2026-W24': 1, '2026-W23': 2, '2026-W22': 2},
      memberCount: 2,
    );

    expect(stats.current, 0);
    expect(stats.record, 2);
  });

  test('traduce errores de callable protegida a mensajes de usuario', () {
    expect(
      mensajeErrorCallableProtegida(
        code: 'unauthenticated',
        message: 'Unauthenticated',
        fallback: 'No se pudo enviar el zumbido',
      ),
      kProtectedCallableUnauthenticatedMessage,
    );
    expect(
      mensajeErrorCallableProtegida(
        code: 'failed-precondition',
        message: 'Los zumbidos solo están disponibles los domingos',
        fallback: 'No se pudo enviar el zumbido',
      ),
      'Los zumbidos solo están disponibles los domingos',
    );
    expect(
      mensajeErrorCallableProtegida(
        code: 'internal',
        message: '',
        fallback: 'No se pudo enviar el zumbido',
      ),
      'No se pudo enviar el zumbido',
    );
    expect(
      mensajeErrorCallableProtegida(
        code: 'internal',
        message: 'internal',
        fallback: 'No se pudo cargar la biblioteca de GIFs',
      ),
      'No se pudo cargar la biblioteca de GIFs',
    );
  });

  testWidgets('el calendario de semanas cabe con texto grande en movil', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final entries = [
      WeekCalendarEntry(
        weekKey: '2026-W23',
        isoYear: 2026,
        isoWeek: 23,
        postedCount: 3,
        memberCount: 4,
        sunday: DateTime(2026, 6, 7),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(
            body: WeekCalendarSheet(
              entries: entries,
              selectedWeekKey: '2026-W23',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ir a una semana'), findsNothing);
    expect(find.text('Esta semana'), findsNothing);
    expect(find.text('Completa'), findsOneWidget);
    expect(find.text('Incompleta'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(WeekCalendarLegend)).dy,
      greaterThan(780),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('la descarga de selfies usa el selector visual de semanas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final entries = [
      WeekCalendarEntry(
        weekKey: '2026-W25',
        isoYear: 2026,
        isoWeek: 25,
        postedCount: 3,
        memberCount: 4,
        sunday: DateTime(2026, 6, 21),
      ),
      WeekCalendarEntry(
        weekKey: '2026-W24',
        isoYear: 2026,
        isoWeek: 24,
        postedCount: 0,
        memberCount: 4,
        sunday: DateTime(2026, 6, 14),
      ),
      WeekCalendarEntry(
        weekKey: '2026-W23',
        isoYear: 2026,
        isoWeek: 23,
        postedCount: 0,
        memberCount: 4,
        sunday: DateTime(2026, 6, 7),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(body: DownloadWeeksSheet(entries: entries)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Descargar selfies'), findsOneWidget);
    expect(find.text('Elige las semanas que quieres guardar'), findsOneWidget);
    expect(find.text('2026 · SEMANAS'), findsOneWidget);
    expect(find.text('Seleccionar todas'), findsOneWidget);
    expect(find.text('1 semana'), findsOneWidget);
    expect(find.text('Selecciona semanas'), findsOneWidget);

    final tiles = find.byType(DownloadWeekTile);
    expect(tiles, findsNWidgets(3));
    final firstTop = tester.getTopLeft(tiles.at(0)).dy;
    expect(tester.getTopLeft(tiles.at(1)).dy, closeTo(firstTop, 1));
    expect(tester.getTopLeft(tiles.at(2)).dy, closeTo(firstTop, 1));

    await tester.tap(find.text('25'));
    await tester.pumpAndSettle();

    expect(find.text('1 seleccionada'), findsOneWidget);
    expect(find.text('Descargar 1 semana · 3 fotos'), findsOneWidget);

    await tester.tap(find.text('25'));
    await tester.pumpAndSettle();

    expect(find.text('Selecciona semanas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat conserva la cuadricula cuando el teclado esta abierto', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 240,
            child: GroupWeeklyContentLayout(
              keyboardVisible: true,
              chatExpanded: true,
              weekSelector: SizedBox(height: 33, child: Text('selector')),
              postsGrid: Text('grid'),
              chatPanel: Text('chat'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('selector'), findsOneWidget);
    expect(find.text('chat'), findsOneWidget);
    expect(find.text('grid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el footer permanece bajo el teclado mientras se oculta', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const footerKey = ValueKey('footer');
    const bodyKey = ValueKey('body');

    Widget buildScaffold(double keyboardInset) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 780),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            body: const SizedBox.expand(key: bodyKey),
            bottomNavigationBar: const SizedBox(key: footerKey, height: 60),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildScaffold(320));
    expect(tester.getTopLeft(find.byKey(footerKey)).dy, 720);
    expect(tester.getSize(find.byKey(bodyKey)).height, 460);

    await tester.pumpWidget(buildScaffold(30));
    expect(tester.getTopLeft(find.byKey(footerKey)).dy, 720);
    expect(tester.getSize(find.byKey(bodyKey)).height, 720);
    expect(tester.takeException(), isNull);
  });

  testWidgets('abrir el chat conserva la cuadricula semanal', (tester) async {
    var gridMountCount = 0;

    Widget buildLayout({required bool chatExpanded}) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: GroupWeeklyContentLayout(
              keyboardVisible: false,
              chatExpanded: chatExpanded,
              expandedChatHeight: 160,
              weekSelector: const SizedBox(height: 33, child: Text('selector')),
              postsGrid: _MountCounter(
                label: 'grid',
                onInit: () => gridMountCount += 1,
              ),
              chatPanel: SizedBox(
                height: chatExpanded ? 160 : kWeeklyChatCollapsedSlotHeight,
                child: const Text('chat'),
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildLayout(chatExpanded: false));
    expect(gridMountCount, 1);

    await tester.pumpWidget(buildLayout(chatExpanded: true));
    await tester.pump();

    expect(gridMountCount, 1);
    expect(find.text('grid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat abierto llega hasta debajo del selector semanal', (
    tester,
  ) async {
    const chatKey = ValueKey('chat-expandido-completo');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: GroupWeeklyContentLayout(
              keyboardVisible: false,
              chatExpanded: true,
              expandedChatHeight: resolverAlturaPanelChatSemanal(
                screenHeight: 780,
              ),
              weekSelector: const SizedBox(height: 33, child: Text('selector')),
              postsGrid: const SizedBox.shrink(),
              chatPanel: const SizedBox(key: chatKey, height: 780),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(chatKey)).height, 382);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrastrar el chat reduce el hueco reservado a la vez', (
    tester,
  ) async {
    var gridHeight = 0.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: GroupWeeklyContentLayout(
              keyboardVisible: false,
              chatExpanded: true,
              chatDragOffset: 50,
              expandedChatHeight: 160,
              weekSelector: const SizedBox(height: 33, child: Text('selector')),
              postsGrid: LayoutBuilder(
                builder: (context, constraints) {
                  gridHeight = constraints.maxHeight;
                  return const Text('grid');
                },
              ),
              chatPanel: const SizedBox(height: 160, child: Text('chat')),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(gridHeight, 272);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la cabecera del chat tambien permite arrastrar hacia abajo', (
    tester,
  ) async {
    var dragStarted = false;
    double? updatedDistance;
    double? endedDistance;
    double? endedVelocity;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 360,
              child: WeeklyChatDragArea(
                onDragStart: () => dragStarted = true,
                onDragUpdate: (distance) => updatedDistance = distance,
                onDragEnd: (distance, velocity) {
                  endedDistance = distance;
                  endedVelocity = velocity;
                },
                child: const WeeklyChatHeader(weekLabel: 'SEMANA 26 / 2026'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.text('CHAT · SEMANA 26 / 2026'),
      const Offset(0, 36),
    );
    await tester.pump();

    expect(dragStarted, isTrue);
    expect(updatedDistance, isNotNull);
    expect(updatedDistance!, greaterThan(0));
    expect(endedDistance, isNotNull);
    expect(endedDistance!, greaterThan(kWeeklyChatDragDismissDistance));
    expect(endedVelocity, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat se puede cerrar al arrastrar desde sus mensajes', (
    tester,
  ) async {
    var dragStarted = false;
    double? updatedDistance;
    double? endedDistance;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 360,
              height: 220,
              child: WeeklyChatDragArea(
                captureDescendantDrags: true,
                onDragStart: () => dragStarted = true,
                onDragUpdate: (distance) => updatedDistance = distance,
                onDragEnd: (distance, _) => endedDistance = distance,
                child: ListView.builder(
                  itemCount: 12,
                  itemBuilder: (_, index) =>
                      SizedBox(height: 40, child: Text('Mensaje $index')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Mensaje 2'), const Offset(0, 36));
    await tester.pump();

    expect(dragStarted, isTrue);
    expect(updatedDistance, isNotNull);
    expect(updatedDistance!, greaterThan(kWeeklyChatDragDismissDistance));
    expect(endedDistance, equals(updatedDistance));
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat abierto acerca los mensajes a la cabecera compacta', (
    tester,
  ) async {
    var dragStarted = false;
    double? updatedDistance;
    double? endedDistance;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 360,
              child: WeeklyChatExpandedDragZone(
                weekLabel: 'SEMANA 26 / 2026',
                onDismiss: () {},
                onDragStart: () => dragStarted = true,
                onDragUpdate: (distance) => updatedDistance = distance,
                onDragEnd: (distance, _) => endedDistance = distance,
              ),
            ),
          ),
        ),
      ),
    );

    final zone = find.byType(WeeklyChatExpandedDragZone);
    expect(tester.getSize(zone).height, lessThanOrEqualTo(60));

    final zoneTopLeft = tester.getTopLeft(zone);
    final zoneHeight = tester.getSize(zone).height;
    await tester.dragFrom(
      zoneTopLeft + Offset(180, zoneHeight - 8),
      const Offset(0, 36),
    );
    await tester.pump();

    expect(dragStarted, isTrue);
    expect(updatedDistance, isNotNull);
    expect(updatedDistance!, greaterThan(0));
    expect(endedDistance, isNotNull);
    expect(endedDistance!, greaterThan(kWeeklyChatDragDismissDistance));
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat finalizado no muestra flecha ni mueve el candado', (
    tester,
  ) async {
    var toggles = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Widget buildChatControl({required bool expanded}) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 360,
              height: kWeeklyChatCollapsedSlotHeight,
              child: expanded
                  ? WeeklyChatInputBar(
                      canWrite: false,
                      controller: controller,
                      onSend: () {},
                      onGif: () {},
                      onToggle: () => toggles += 1,
                    )
                  : WeeklyChatCollapsedBar(
                      canWrite: false,
                      unreadCount: 2,
                      onToggle: () => toggles += 1,
                    ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChatControl(expanded: false));
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    final collapsedLockLeft = tester.getTopLeft(
      find.byIcon(Icons.lock_outline_rounded),
    );

    await tester.tap(find.text('Chat de domingo finalizado'));
    await tester.pump();
    expect(toggles, 1);

    await tester.pumpWidget(buildChatControl(expanded: true));
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    final expandedLockLeft = tester.getTopLeft(
      find.byIcon(Icons.lock_outline_rounded),
    );

    await tester.tap(find.text('Chat de domingo finalizado'));
    await tester.pump();

    expect(toggles, 2);
    expect(expandedLockLeft.dx, collapsedLockLeft.dx);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el chat expandido cabe con teclado abierto en movil', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            padding: EdgeInsets.only(top: 24),
            viewInsets: EdgeInsets.only(bottom: 320),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            body: SafeArea(
              child: SizedBox(
                height: 241,
                child: Column(
                  children: [
                    const SizedBox(
                      height: kGroupWeekSelectorKeyboardReserveHeight,
                    ),
                    Expanded(
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: ssBg,
                          border: Border(
                            top: BorderSide(color: ssSeparator, width: 1),
                          ),
                        ),
                        child: Column(
                          children: [
                            const WeeklyChatHeader(weekLabel: 'ESTA SEMANA'),
                            const Expanded(
                              child: WeeklyChatEmptyState(canWrite: true),
                            ),
                            WeeklyChatInputBar(
                              canWrite: true,
                              controller: controller,
                              onSend: () {},
                              onGif: () {},
                              onToggle: () {},
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).textAlign,
      TextAlign.start,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).textAlignVertical,
      TextAlignVertical.center,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el boton de enviar chat se activa cuando hay texto', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    var sends = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 360,
              height: kWeeklyChatCollapsedSlotHeight,
              child: WeeklyChatInputBar(
                canWrite: true,
                controller: controller,
                onSend: () => sends += 1,
                onGif: () {},
                onToggle: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final sendButton = find.byKey(const ValueKey('weekly-chat-send-button'));

    expect(tester.widget<Material>(sendButton).color, ssOrangeMid);
    await tester.tap(sendButton);
    await tester.pump();
    expect(sends, 0);

    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pump();

    expect(tester.widget<Material>(sendButton).color, ssOrange);
    await tester.tap(sendButton);
    await tester.pump();
    expect(sends, 1);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();

    expect(tester.widget<Material>(sendButton).color, ssOrangeMid);
  });

  test('la subida tardia exige pertenecer al grupo el domingo anterior', () {
    final monday = DateTime(2026, 6, 15, 10);
    final previousWeekKey = obtenerWeekKeyDomingoAnterior(now: monday);

    expect(
      miembroPuedeSubirSelfieLunesConRetraso(
        previousWeekKey,
        DateTime(2026, 6, 14, 23, 59),
        now: monday,
      ),
      isTrue,
    );
    expect(
      miembroPuedeSubirSelfieLunesConRetraso(
        previousWeekKey,
        DateTime(2026, 6, 15),
        now: monday,
      ),
      isFalse,
    );
  });

  testWidgets('cancelar cambio de nombre de grupo cierra sin error', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<String>(
                    context: context,
                    builder: (_) => const GroupNameEditDialog(
                      initialName: 'Grupo de prueba',
                    ),
                  );
                },
                child: const Text('Abrir dialogo'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir dialogo'));
    await tester.pumpAndSettle();

    expect(find.text('Cambiar nombre del grupo'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.text('Cambiar nombre del grupo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelar cambio de nombre en grupo cierra sin error', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<String>(
                    context: context,
                    builder: (_) => const GroupMemberNameEditDialog(
                      initialName: 'Lucrezia',
                    ),
                  );
                },
                child: const Text('Abrir dialogo'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir dialogo'));
    await tester.pumpAndSettle();

    expect(find.text('Cambiar nombre en este grupo'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(find.text('Cambiar nombre en este grupo'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _MountCounter extends StatefulWidget {
  final String label;
  final VoidCallback onInit;

  const _MountCounter({required this.label, required this.onInit});

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.label);
  }
}
