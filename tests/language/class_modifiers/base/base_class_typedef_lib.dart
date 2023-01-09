// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// SharedOptions=--enable-experiment=class-modifiers

base class BaseClass {
  int foo = 0;
}

typedef BaseClassTypeDef = BaseClass;

class A extends BaseClassTypeDef {}

class B implements BaseClassTypeDef {
  @override
  int foo = 1;
}
