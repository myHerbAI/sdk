// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// SharedOptions=--enable-experiment=macros
// ignore_for_file: deprecated_member_use

// There is no public API exposed yet, the in-progress API lives here.
import 'package:_fe_analyzer_shared/src/macros/api.dart';

// TODO: Support collections, extending serializable classes, and more.
macro class JsonSerializable implements ClassDeclarationsMacro {
  const JsonSerializable();

  @override
  Future<void> buildDeclarationsForClass(
      ClassDeclaration clazz, MemberDeclarationBuilder builder) async {
    var constructors = await builder.constructorsOf(clazz);
    if (constructors.any((c) => c.identifier.name == 'fromJson')) {
      throw ArgumentError('There is already a `fromJson` constructor for '
          '`${clazz.identifier.name}`, so one could not be added.');
    }

    var map = await builder.resolveIdentifier(_dartCore, 'Map');
    var string = NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'String'));
    var object = NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'Object'));
    var mapStringObject = NamedTypeAnnotationCode(
      name: map, typeArguments: [string, object.asNullable]);

    // TODO: This only works because the macro file lives right next to the file
    // it is applied to.
    var jsonSerializableUri =
        clazz.library.uri.resolve('json_serializable.dart');

    builder.declareInType(DeclarationCode.fromParts([
      '  @',
      await builder.resolveIdentifier(jsonSerializableUri, 'FromJson'),
      // TODO(language#3580): Remove/replace 'external'?
      '()\n  external ',
      clazz.identifier.name,
      '.fromJson(',
      mapStringObject,
      ' json);',
    ]));

    builder.declareInType(DeclarationCode.fromParts([
      '  @',
      await builder.resolveIdentifier(jsonSerializableUri, 'ToJson'),
      // TODO(language#3580): Remove/replace 'external'?
      '()\n  external ',
      mapStringObject,
      ' toJson();',
    ]));
  }
}

/// A macro applied to a fromJson constructor, which fills in the initializer list.
macro class FromJson implements ConstructorDefinitionMacro {
  const FromJson();

  @override
  Future<void> buildDefinitionForConstructor(ConstructorDeclaration constructor,
      ConstructorDefinitionBuilder builder) async {
    // TODO: Validate we are running on a valid fromJson constructor.

    // TODO: support extending other classes.
    var clazz = (await builder.typeDeclarationOf(constructor.definingType))
        as ClassDeclaration;
    var superclass = clazz.superclass;
    var superclassHasFromJson = false;
    var object = NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'Object'));
    if (superclass != null &&
        !await (await builder.resolve(
                NamedTypeAnnotationCode(name: superclass.identifier)))
            .isExactly(await builder.resolve(object))) {
      var superclassDeclaration = await builder.typeDeclarationOf(superclass.identifier);
      var superclassConstructors = await builder.constructorsOf(superclassDeclaration);
      for (var constructor in superclassConstructors) {
        if (constructor.identifier.name == 'fromJson') {
          // TODO: Validate this is a valid fromJson constructor.
          superclassHasFromJson = true;
          break;
        }
      }
      if (!superclassHasFromJson) {
        throw UnsupportedError(
          'Serialization of classes that extend other classes is only '
          'supported if those classes have a valid '
          '`fromJson(Map<String, Object?> json)` constructor.');
      }
    }

    var string = NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'String'));
    var mapStringObject = NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'Map'),
        typeArguments: [string, object.asNullable]);
    var fields = await builder.fieldsOf(clazz);
    var jsonParam = constructor.positionalParameters.single.identifier;
    builder.augment(initializers: [
      for (var field in fields)
        RawCode.fromParts([
          field.identifier,
          ' = ',
          await _convertFieldFromJson(
            field, jsonParam, builder, mapStringObject),
        ]),
      if (superclassHasFromJson)
        RawCode.fromParts([
          'super.fromJson(',
          jsonParam,
          ')',
        ]),
    ]);
  }

  // TODO: Support nested collections.
  Future<Code> _convertFieldFromJson(FieldDeclaration field,
      Identifier jsonParam, DefinitionBuilder builder,
      NamedTypeAnnotationCode mapStringObject) async {
    var fieldType = field.type;
    if (fieldType is! NamedTypeAnnotation) {
      throw ArgumentError(
          'Only fields with named types are allowed on serializable classes, '
          'but `${field.identifier.name}` was not a named type.');
    }
    var fieldTypeDecl = await builder.declarationOf(fieldType.identifier);
    while (fieldTypeDecl is TypeAliasDeclaration) {
      var aliasedType = fieldTypeDecl.aliasedType;
      if (aliasedType is! NamedTypeAnnotation) {
        throw ArgumentError(
            'Only fields with named types are allowed on serializable classes, '
            'but `${field.identifier.name}` did not resolve to a named type.');
      }
    }
    if (fieldTypeDecl is! ClassDeclaration) {
      throw ArgumentError(
          'Only classes are supported in field types for serializable classes, '
          'but the field `${field.identifier.name}` does not have a class '
          'type.');
    }

    var fieldConstructors = await builder.constructorsOf(fieldTypeDecl);
    var fieldTypeFromJson = fieldConstructors
        .firstWhereOrNull((c) => c.identifier.name == 'fromJson')
        ?.identifier;
    if (fieldTypeFromJson != null) {
      return RawCode.fromParts([
        fieldTypeFromJson,
        '(',
        jsonParam,
        '["${field.identifier.name}"] as ',
        mapStringObject,
        ')',
      ]);
    } else {
      return RawCode.fromParts([
        jsonParam,
        // TODO: support nested serializable types.
        '["${field.identifier.name}"] as ',
        field.type.code,
      ]);
    }
  }
}

/// A macro applied to a toJson instance method, which fills in the body.
macro class ToJson implements MethodDefinitionMacro {
  const ToJson();

  @override
  Future<void> buildDefinitionForMethod(
      MethodDeclaration method, FunctionDefinitionBuilder builder) async {
    // TODO: Validate we are running on a valid toJson method.

    // TODO: support extending other classes.
    final clazz = (await builder.typeDeclarationOf(method.definingType))
        as ClassDeclaration;
    var object = await builder.resolve(NamedTypeAnnotationCode(
        name: await builder.resolveIdentifier(_dartCore, 'Object')));
    var superclass = clazz.superclass;
    var superclassHasToJson = false;
    if (superclass != null &&
        !await (await builder.resolve(
                NamedTypeAnnotationCode(name: superclass.identifier)))
            .isExactly(object)) {
      var superclassDeclaration = await builder.typeDeclarationOf(superclass.identifier);
      var superclassMethods = await builder.methodsOf(superclassDeclaration);
      for (var method in superclassMethods) {
        if (method.identifier.name == 'toJson') {
          // TODO: Validate this is a valid toJson method.
          superclassHasToJson = true;
          break;
        }
      }
      if (!superclassHasToJson) {
        throw UnsupportedError(
          'Serialization of classes that extend other classes is only '
          'supported if those classes have a valid '
          '`Map<String, Object?> toJson()` method.');
      }
    }

    var fields = await builder.fieldsOf(clazz);
    builder.augment(FunctionBodyCode.fromParts([
      ' => {',
      // TODO: Avoid the extra copying here.
      if (superclassHasToJson) '\n    ...super.toJson(),',
      for (var field in fields)
        RawCode.fromParts([
          '\n    \'',
          field.identifier.name,
          '\'',
          ': ',
          await _convertFieldToJson(field, builder),
          ',',
        ]),
      '\n  };',
    ]));
  }

  // TODO: Support nested collections.
  Future<Code> _convertFieldToJson(
      FieldDeclaration field, DefinitionBuilder builder) async {
    var fieldType = field.type;
    if (fieldType is! NamedTypeAnnotation) {
      throw ArgumentError(
          'Only fields with named types are allowed on serializable classes, '
          'but `${field.identifier.name}` was not a named type.');
    }
    var fieldTypeDecl = await builder.typeDeclarationOf(fieldType.identifier);
    while (fieldTypeDecl is TypeAliasDeclaration) {
      var aliasedType = fieldTypeDecl.aliasedType;
      if (aliasedType is! NamedTypeAnnotation) {
        throw ArgumentError(
            'Only fields with named types are allowed on serializable classes, '
            'but `${field.identifier.name}` did not resolve to a named type.');
      }
    }
    if (fieldTypeDecl is! ClassDeclaration) {
      throw ArgumentError(
          'Only classes are supported in field types for serializable classes, '
          'but the field `${field.identifier.name}` does not have a class '
          'type.');
    }

    var fieldTypeMethods = await builder.methodsOf(fieldTypeDecl);
    var fieldToJson = fieldTypeMethods
        .firstWhereOrNull((c) => c.identifier.name == 'toJson')
        ?.identifier;
    if (fieldToJson != null) {
      return RawCode.fromParts([
        field.identifier,
        '.toJson()',
      ]);
    } else {
      // TODO: Check that it is a valid type we can serialize.
      return RawCode.fromParts([
        field.identifier,
      ]);
    }
  }
}

final _dartCore = Uri.parse('dart:core');

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) compare) {
    for (var item in this) {
      if (compare(item)) return item;
    }
    return null;
  }
}
