// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// test w/ `pub run test -N omit_local_variable_types`

void printItems(Iterable items) {
  for (var item in items) { // OK
    print(item);
  }
}

void foo() {
  final array = [];
  for (a in array) { // OK

  }
}

int goodGlobalVariable = 3, a = 4; // OK

Map<int, List<Person>> badGroupByZip(Iterable<Person> people) {
  Map<int, List<Person>> peopleByZip = <int, List<Person>>{}; // LINT

  for (Person person in people) { // LINT
    peopleByZip.putIfAbsent(person.zip, () => <Person>[]);
    peopleByZip[person.zip].add(person);
  }

  return peopleByZip;
}

Map<int, List<Person>> goodGroupByZip(Iterable<Person> people) {
  var peopleByZip = <int, List<Person>>{}; // OK

  for (final person in people) { // OK
    peopleByZip.putIfAbsent(person.zip, () => <Person>[]);
    peopleByZip[person.zip].add(person);
  }

  return peopleByZip;
}

class Person {
  int zip = 3; // OK

  Person() {
    Iterable a = [], b = new Iterable.empty(); // OK
    Iterable c = new Iterable.empty(), d = new Iterable.empty(); // LINT
  }
}

class LinkedListNode {
  LinkedListNode next;
}
void traverse(LinkedListNode head) {
  for (LinkedListNode node = head; node != null; node = node.next) { // LINT
    // doSomething
  }
}
