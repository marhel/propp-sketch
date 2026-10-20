# propp-sketch

A throwaway, hand-written sketch of property-based testing (PBT) in Gleam. It was
written to make a design discussion concrete: how PBT could be added to Markus Eliasson's
[garanti](https://github.com/eliasson/garanti), a Gleam test framework. It is not
a library, and not a proposal for garanti's code.

The sketch uses *choice sequences*, the approach of Hypothesis and minithesis.
Generators never call a random function. Instead, they read integer "choices" from
a list. To shrink a failing example, the sketch edits that list and runs the same
generator on it again. Every generator therefore gets shrinking for free,
including generators for composed domain types.

## What to read

- [`src/propp.gleam`](src/propp.gleam) is the whole sketch, about 220 lines, hand-written (these days!?).
- [`docs/pbt-key-points.md`](docs/pbt-key-points.md) walks through the design
  step by step, with code from the sketch. It also says where the sketch takes
  shortcuts. Mostly Claude-written but with lots of input from me. Start here.
- [`docs/property-based-testing.md`](docs/property-based-testing.md) is the Claude-written, much
  longer background: the alternatives (rose trees, choice sequences, random
  search by size), prior art, and open questions. Less input from me.

The git history follows steps 1 to 5 of the key points in order. Reading it
commit by commit shows how the sketch started simple and grew:

1. Generators over a plain list of integers
   ([f14a146](https://github.com/marhel/propp-sketch/commit/f14a146598a710a21ba963e501b53387a2123492)).
2. Running a property on random choices (also
   [f14a146](https://github.com/marhel/propp-sketch/commit/f14a146598a710a21ba963e501b53387a2123492),
   with `for_all` added later in
   [49d45a6](https://github.com/marhel/propp-sketch/commit/49d45a6b00a13ab455a486f7e5a74df034673f31)).
3. Recording and replaying choices
   ([5ba4bb5](https://github.com/marhel/propp-sketch/commit/5ba4bb58c0d2793496d6d0cea2453960fd485658)).
4. A first, deliberately crude shrinker
   ([3300306](https://github.com/marhel/propp-sketch/commit/330030686f5e417d31681e974bb79dc3346ede2d)).
5. A composed generator for a domain type
   ([af31513](https://github.com/marhel/propp-sketch/commit/af315136c215118cba5d431694c6a943c610be0f)).

## Running it

```sh
gleam run                       # BEAM
gleam run --target javascript   # JS
```

`main` checks two properties and prints the outcome:

- `is_three_digits` on integers from 100 to 1100 (yes, the property is intentionally flawed)
- A automated bar (the kind where you drink) with a 'bug' inserted; That 16 is old enough for alcohol, checked against the property "a person who
  is served alcohol is at least 20".

Both properties fail on purpose. The output shows the shrunk counterexample, the
number of examples that passed before it, and the choices that reproduce it, e.g.
`Disproven(DrinkOrder(Person(16), Beer), 5, [6, 1])`.

The shrinker is random search with a small budget, so the result varies between
runs and is not always minimal. Why that is, and what to do instead, is covered
in step 4 of the key points.
