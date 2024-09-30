// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';

/// [ExecutableElement], its parameters, and operations on them.
class ExecutableParameters {
  final AnalysisSessionHelper sessionHelper;
  final ExecutableElement executable;
  final ExecutableElement2 executable2;

  final List<ParameterElement> required = [];
  final List<ParameterElement> optionalPositional = [];
  final List<ParameterElement> named = [];

  final List<FormalParameterElement> required2 = [];
  final List<FormalParameterElement> optionalPositional2 = [];
  final List<FormalParameterElement> named2 = [];

  ExecutableParameters._(
    this.sessionHelper,
    this.executable,
    this.executable2,
  ) {
    for (var parameter in executable.parameters) {
      if (parameter.isRequiredPositional) {
        required.add(parameter);
        required2.add(parameter.element);
      } else if (parameter.isOptionalPositional) {
        optionalPositional.add(parameter);
        optionalPositional2.add(parameter.element);
      } else if (parameter.isNamed) {
        named.add(parameter);
        named2.add(parameter.element);
      }
    }
  }

  /// Return the path of the file in which the executable is declared.
  String get file => executable.source.fullName;

  /// Return the names of the named parameters.
  List<String> get namedNames {
    return named.map((parameter) => parameter.name).toList();
  }

  /// Return the [FormalParameterList] of the [executable], or `null` if it
  /// can't be found.
  Future<FormalParameterList?> getParameterList() async {
    var result = await sessionHelper.getElementDeclaration(executable);
    var targetDeclaration = result?.node;
    if (targetDeclaration is ConstructorDeclaration) {
      return targetDeclaration.parameters;
    } else if (targetDeclaration is FunctionDeclaration) {
      var function = targetDeclaration.functionExpression;
      return function.parameters;
    } else if (targetDeclaration is MethodDeclaration) {
      return targetDeclaration.parameters;
    }
    return null;
  }

  /// Return the [FormalParameter] of the [element] in [FormalParameterList],
  /// or `null` if it can't be found.
  Future<FormalParameter?> getParameterNode(ParameterElement element) async {
    var result = await sessionHelper.getElementDeclaration(element);
    var declaration = result?.node;
    for (var node = declaration; node != null; node = node.parent) {
      if (node is FormalParameter && node.parent is FormalParameterList) {
        return node;
      }
    }
    return null;
  }

  /// Return the [FormalParameter] of the [fragment] in [FormalParameterList],
  /// or `null` if it can't be found.
  Future<FormalParameter?> getParameterNode2(
      FormalParameterFragment fragment) async {
    var result = await sessionHelper.getElementDeclaration2(fragment);
    var declaration = result?.node;
    for (var node = declaration; node != null; node = node.parent) {
      if (node is FormalParameter && node.parent is FormalParameterList) {
        return node;
      }
    }
    return null;
  }

  static ExecutableParameters? forInvocation(
      AnalysisSessionHelper sessionHelper, AstNode? invocation) {
    Element? element;
    Element2? element2;
    // This doesn't handle FunctionExpressionInvocation.
    if (invocation is Annotation) {
      element = invocation.element;
      element2 = invocation.element2;
    } else if (invocation is InstanceCreationExpression) {
      element = invocation.constructorName.staticElement;
      element2 = invocation.constructorName.element;
    } else if (invocation is MethodInvocation) {
      element = invocation.methodName.staticElement;
      element2 = invocation.methodName.element;
    } else if (invocation is ConstructorReferenceNode) {
      element = invocation.staticElement;
      element2 = invocation.element;
    }
    if (element is ExecutableElement &&
        !element.isSynthetic &&
        element2 is ExecutableElement2 &&
        !element2.isSynthetic) {
      return ExecutableParameters._(sessionHelper, element, element2);
    } else {
      return null;
    }
  }
}
