# Property-based testing in Garanti — background for discussion

Status: draft. This is input for discussion, not a set of decisions: every choice
below is the maintainer's to make. Where the authors lean one way, it is marked
as such, with the reasoning, so it can be weighed rather than adopted.

## Background

Garanti has example-based tests (`Test`) and table-driven tests (`garanti/table`),
but no support for property-based testing (PBT): no random input generation, no
seeds, no shrinking.

Garanti's existing design makes PBT easy to add:

- A `Test` is just `fn() -> AssertionResult`. A property can be a regular `Test`
  that runs many generated examples internally, so the runner, focus handling and
  reporting stay unchanged.
- A property body can return an `AssertionResult`, which means every existing
  `expect.*` matcher, and the diff output, can be reused inside properties as is.
- `executor.run_catching` already catches panics. A property needs to catch them
  per generated example, so that panicking inputs can also be shrunk.

## Roadmap sketch

One possible order, as a sketch. Each step is useful on its own and builds on the
previous one, and the early steps start with the simplest thing that works.
minithesis's porting notes give the same priority order: "Anything that supports
[generation and shrinking] is a reasonable good first porting goal." The
companion document `pbt-key-points.md` walks through the same steps with code from
the [prototype](#the-prototype).

1. **Generators read a list of choices.** This step already commits to a
   generator representation, see [Question 1](#question-1-generator-representation-and-shrinking-strategy).
   `draw`, `map` and `int_range` over a plain list, tested with literal lists.
2. **Running properties:** run N examples on fresh random choices, report the
   counterexample and the choices it consumed, and catch panics per example.
   Separate per-example and per-run results (see [Core types](#core-types)).
3. **Recording and replaying choices:** draw on demand and record, or replay a
   given list. This is what shrinking needs (see [Core types](#core-types)).
4. **Shrinking:** see [The shrinker](#the-shrinker).
5. **Composed and library generators:** `flat_map` (bind), `map2`, `tuple2`, `bool`,
   `constant`, `list_of`, `one_of`, `frequency`, sizing, and a bias towards edge
   cases (see [Choice encoding](#choice-encoding)).
6. **Rejecting irrelevant input:** `assume` / `filter` with a discard budget that
   ends in "gave up" instead of a silent pass (see [Question 3](#question-3-discards-and-gave-up)).
   Prefer constructive generators to filtering. Add `classify`/`label` statistics so
   that a skewed distribution is visible.
7. **Seedable PRNG.** The same seed gives the same sequence *within a target*.
   Matching sequences across BEAM and JS is a nice-to-have. The BEAM side can use
   `rand:seed_s/2` and `rand:uniform_s/2` (purely functional). JS needs a small PRNG
   of its own, since `Math.random` cannot be seeded (e.g. mulberry32). An opaque
   `Seed` type sits behind `@external`, the same way `run_catching` does. This can
   come late, since only `draw` and the runner see the random source.
8. **Reporting, replay and persistence:** seed via config or an environment
   variable (see [Question 4](#question-4-reporting-counterexamples-and-seeds)).
   Later, store failing examples so they run first next time. In minithesis this
   is a dozen lines: the failing choice sequence is stored under the test's name
   and deleted once the test passes.
9. **Metamorphic tests and common laws** as thin layers on top of properties:
   `roundtrip(encode, decode)`, `idempotent`, `commutative`, invariance under
   permutation, `equivalent_to(reference_impl)`, `metamorphic(gen, transform, relation)`.
10. **Stateful (model-based) testing:** commands with `precondition`, `next_state`,
    `run` and `postcondition`, generated from the model state. Shrinking removes
    commands and re-checks preconditions.
11. **Extras:** coverage requirements (`cover(10%, "empty list")`), targeted PBT,
    and parallel/linearizability testing (BEAM only). Andjelkovic's survey
    ["The sad state of property-based testing libraries"](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html)
    compares libraries on stateful and parallel testing, and is worth reading before
    steps 10–11.

## The prototype

There is a throwaway, hand-written prototype in `src/propp.gleam` (not
part of garanti; about 220 lines). It is a **deliberately simple variant of
strategy B** (choice sequences, see Question 1), written to make the ideas
concrete. It is not a proposal for garanti's code. Its git history follows
roadmap steps 1 to 5 in order. It runs on both
targets:

```sh
gleam run                       # BEAM
gleam run --target javascript   # JS
```

**What it implements:**

- `Generator(run: fn(Choices) -> Result(#(a, Choices), Rejected))`. In steps 1
  and 2, `Choices` is an alias for `List(Int)`, pre-filled with random numbers,
  and `draw` wraps with modulo. Step 3 turns `Choices` into a type that records
  what is drawn, from a `Random` or a `Replay` source, and `draw` draws within
  range. The generator type and signatures stay the same.
- `draw`, `map`, `flat_map`, `map2`, `int_range`, and generators for a bar's
  drink orders (an age and a drink).
- `check1` for one example, giving `Holds`, `Counterexample` or `Discarded`, and
  a loop giving `Passed`, `Disproven` or `GaveUp`. `for_all` runs 20 examples.
- A shrinker by random search: each candidate lowers every choice to a random
  value in `0..=c`, and is replayed through `check1`.
- Two properties: `is_three_digits` on `int_range(100, 1100)`, and "a person who
  is served alcohol is at least 20" against a bar that thinks 16 is old enough.

**Shortcuts it takes, each discussed later in this document:**

| Shortcut | Instead of |
|---|---|
| `int.random`, not seedable | A seedable PRNG (roadmap step 7) |
| No cap on the number of choices | An entropy cap ([Core types](#core-types)) |
| `int_range` shrinks towards its lower bound, and doesn't check its bounds | Zigzag towards zero, total generators ([Choice encoding](#choice-encoding)) |
| Random-search shrinker with a budget of 20 | Deterministic passes ([The shrinker](#the-shrinker)) |
| No shortlex check, and the first rejected candidate ends shrinking | The acceptance rule ([The shrinker](#the-shrinker)) |
| Property is `fn(a) -> Bool`, no panic catching, fixed 20 runs | `AssertionResult`, per-example panic catching, configuration (roadmap step 2) |
| Gives up at the first discard, no `filter`/`assume` | A discard budget ([Question 3](#question-3-discards-and-gave-up)) |
| No `list_of`, `one_of` and so on | [Choice encoding](#choice-encoding), [Sizing generated data](#sizing-generated-data) |
| No slippage or flakiness checks, no database | [What counts as the same failure](#what-counts-as-the-same-failure), roadmap step 8 |

The numbers quoted later from "the prototype" (the modulo example, how far random
search gets) come from these shortcuts. That is exactly why they are there.

## Question 1: generator representation and shrinking strategy

This has to be decided before step 1, even though shrinking only arrives in step 4.
The representation of a generator determines which shrinking strategies are
possible, and changing it later means rewriting every generator.

### Terminology

- **Type-based (external) shrinking:** the shrinker is separate from the generator
  and is chosen by the value's *type*. This is the original QuickCheck model
  (Haskell). QuickCheck 1 had no shrinking at all, since its `Arbitrary` class had
  only `arbitrary` and `coarbitrary`. QuickCheck 2 added `shrink :: a -> [a]` to
  `Arbitrary`. FsCheck (F#) and ScalaCheck (Scala) follow the same model.
- **Integrated shrinking:** the *generator* determines how its values shrink, so
  shrinking follows `map`, `filter` and `flat_map`. The term comes from the Hypothesis
  and Hedgehog communities. Strategies A, B and C below are three ways to do it.
- **Internal shrinking / internal reduction:** MacIver & Donaldson's name for B
  specifically, "a form of integrated shrinking" that works on the random choices
  instead of on values.

Rose trees are not unique to integrated shrinking. Applying QuickCheck's `shrink`
repeatedly also produces a tree of candidates, and QuickCheck searches it the same
way. The difference is *where the tree comes from*. In QuickCheck, the type's
`shrink` builds it from the finished value, after generation. In strategy A, the generator
builds it together with the value, so the generator's transformations and
invariants carry over.

### Why not type-based shrinking

Type-based shrinking does not compose through `map`. A value from
`map(int, to_prime)` is shrunk as an int, and can "successfully" shrink to a
non-prime, i.e. to a *different* failure. Hypothesis's
["Integrated vs type based shrinking"](https://hypothesis.works/articles/integrated-shrinking/)
makes the same point with even numbers. Custom types also need a hand-written
shrinker, and per CsCheck's comparison "people don't write this code". Not
considered further.

### Three integrated alternatives

They are fundamentally different ways to find a smaller failing input:

| | How a smaller candidate is found | Implementations (language) |
|---|---|---|
| **A. Rose trees** | Walk a tree of candidates that the generator built alongside the failing *value* | Hedgehog (Haskell), test.check (Clojure), QCheck2 (OCaml), qcheck (Gleam) |
| **B. Choice sequences** | Edit the recorded *random choices* and replay the generator | Hypothesis and minithesis (Python), elm-minithesis, elm-microthesis and elm-test (Elm), theft (C), DeepState (C++) |
| **C. Random search by size** | Generate *fresh random values*; test only those smaller than the current minimum | CsCheck (C#), as far as we know the only one |

Verified against source code: qcheck, Hypothesis, minithesis, elm-minithesis,
elm-microthesis and CsCheck. The rest are cited from secondary sources:
- test.check, theft and DeepState from the ECOOP paper,
- Hedgehog from its documentation, as quoted by CsCheck,
- QCheck2 from a Tweag blog post title,
- elm-test from a web search.

[qcheck](https://github.com/mooreryan/gleam_qcheck) is an existing Gleam PBT
library by Ryan M. Moore, who has also contributed to garanti (PRs #17, #19, #24
and #25: docs, diff output on failure, `string.inspect` in failure messages, a diff
legend). Its source confirms strategy A:
`Generator(fn(Seed) -> #(Tree(a), Seed))`. It was inspired by the OCaml libraries
QCheck and base_quickcheck, and supports both Gleam targets.

Strategies A and B are both local searches from the failing example. They differ in whether
they edit the value or the randomness behind it. Strategy C does not start from the failing
example at all.

### A. Rose trees (Hedgehog, qcheck)

A generator produces a value together with a lazy tree of smaller candidates:

```gleam
pub type Tree(a) {
  Tree(value: a, shrinks: fn() -> List(Tree(a)))
}

pub type Generator(a) {
  Generator(run: fn(Seed, Int) -> Tree(a))  // Int = size
}
```

Shrinking walks the tree, descending into the first child that still fails.

- `map` maps over the whole tree, and `filter` prunes subtrees. Invariants survive
  shrinking, so a constructively generated prime shrinks to smaller primes.
- `flat_map` (bind) is the weak spot. When the outer value shrinks, the inner value is
  *regenerated*, and its own shrinking progress is lost. Hedgehog recommends
  applicative combinators over bind for that reason.
- Every combinator (`map2`, `list`, `one_of`, …) must handle the tree, so the
  shrinking logic is spread across all of them.
- Gleam is strict, so children must be thunks. That is easy to get wrong, since
  building the tree eagerly blows up.
- MacIver & Donaldson concede that this model "is significantly simpler to
  implement and easier to understand" than strategy B.

### B. Choice sequences / internal shrinking (Hypothesis) — our leaning

A generator is a deterministic **parser of a sequence of choices**. During
generation, the choices come from the PRNG and are recorded. The recorded list
*is* the example, and replaying it reproduces the value. Shrinking edits the
*list*, not the value, and keeps a candidate if it still fails. The reduced example
is "as if the generator had been implausibly lucky" (MacIver & Donaldson, ECOOP
2020). The [prototype](#the-prototype) and both Elm ports use essentially
this shape:

```gleam
pub type Generator(a) {
  Generator(run: fn(Choices) -> Result(#(a, Choices), Rejected))
}
```

"Smaller" means smaller in **shortlex order** (short for "shortest, then
lexicographic"). It compares choice lists first by length, and lists of equal
length element by element from the left, like words in a dictionary:

```
[5] < [0, 0] < [0, 0, 7] < [0, 1, 0] < [1, 0, 0]
```

- `[5] < [0, 0] < [0, 0, 7]`: a shorter list wins, whatever the values.
- `[0, 0, 7] < [0, 1, 0]`: same length, so the first difference decides (0 < 1,
  and the trailing 7 is never looked at).
- `[0, 1, 0] < [1, 0, 0]`: the leftmost position dominates, so an early choice
  weighs more than all the later ones together.

Choices are non-negative, so this order has no infinitely long chain of
ever-smaller lists. The length can only drop finitely many times. At a fixed length,
the first element can only drop finitely many times, and between those drops the
second can only drop finitely many times, and so on. There can still be infinitely
many smaller lists (`[0, n] < [1, 0]` for every `n`), but never an endless
*descent*. So a shrinker that only ever moves to a shortlex-smaller list must
stop. Shorter lists mostly mean smaller values (fewer
elements, less recursion), and lower choices mean simpler ones (see
[Choice encoding](#choice-encoding)). Hypothesis uses this order as its
definition of "simpler", and MacIver & Donaldson describe strategy B as
"shortlex optimisation over choice sequences".

Consequences:

- **One shrinker for everything.** `map`, `flat_map`, `filter`, `one_of` and stateful
  command sequences need no shrinking code. The generator is replayed, so its
  invariants always hold, and `flat_map` shrinks well because outer and inner values
  are just positions in the same list. In the prototype, a drink order built with
  `map2` shrank to a 16-year-old ordering a beer, choices `[6, 1]`, without any
  code for shrinking drink orders.
- **Generators can be written in step 1 without thinking about shrinking**, and
  steps 3 and 4 add shrinking without changing the generator API. In the
  prototype, only `draw` among the generators changed.
- **Replay, persistence, targeted PBT and fuzzing come almost for free.** The
  choice sequence is a single interface. A database stores it. Targeted PBT hill
  climbs on it (minithesis: `target(score)`, then ±1 and doubling steps). An
  external fuzzer can supply it, as in crowbar (OCaml, AFL) and DeepState (C++).
  Every input found is one the generator could have produced.
- **The cost:** shrink quality depends on how generators encode values as choices
  (see [Choice encoding](#choice-encoding)), and the shrinker is a set of
  heuristic passes. When it gets stuck, the reason is less obvious than with a
  tree. MacIver & Donaldson argue that this is "a limitation of its reducer rather
  than the model": it can be fixed in the library, without changing user code.
- **Not claimed: better quality or speed.** "Moderately better results … but can
  be a fair bit slower." The paper's evaluation:
  - **Five small benchmarks** from earlier QuickCheck shrinking research
    (SmartCheck), e.g. `bound5` and `binheap`: examples were similar or smaller
    than QuickCheck's (`bound5`: 2.08 vs. 11.30), at 2–3× the test runs
    (`binheap`: 170 vs. 88).
  - **SymPy**, a Python library for symbolic mathematics: the failing tests were
    sequences of SymPy API calls that triggered real bugs. Hypothesis needed 20.6×
    as many test runs as *delta debugging*, a classic general-purpose algorithm
    for minimising failing inputs, and its results were 83% of the size.

Strategy B implementations whose source we have read: Hypothesis (selected parts, see
Sources), [minithesis](https://github.com/DRMacIver/minithesis) (Python, under 500
lines, by Hypothesis's author, written "for people who want to implement a
property-based testing library for non-Python languages"), and its Elm ports
[elm-minithesis](https://github.com/Janiczek/elm-minithesis) and
[elm-microthesis](https://github.com/Janiczek/elm-microthesis). Since Elm is pure,
strict and has no exceptions, **elm-microthesis (~1,500 lines) is the most direct
template for garanti**. Not studied, only cited as strategy B implementations:
[theft](https://github.com/silentbicycle/theft) (C) and DeepState (C++), by the
ECOOP paper, and elm-test, by a web search.

### C. Random search by size (CsCheck)

Strategy C is a separate model, not a variant of strategy A or B. In
[CsCheck](https://github.com/AnthonyLloyd/CsCheck) (C#), a generator returns a
value *and a size*, a generator-defined chain of integers compared
lexicographically. For an `int` this is roughly its bit length, and for a list its
length, then the summed element sizes. After the first failure, nothing is derived
from the failing value. The runner keeps generating *fresh random values* in
parallel on all cores. It only runs the test on values smaller than the smallest
failure so far, and generators abort early when they would exceed it. Each
candidate has its own PCG seed, so the shrunk case is reproducible from its seed,
and the search can be resumed later (e.g. after a CI failure). Its author calls
this a "Monte-Carlo shrinker", as opposed to "path explorer shrinkers".

- **No local minima.** Any smaller failure can be generated, hence the claim to
  "always shrink to the simplest example (given enough time)". Examples from
  [Comparison.md](https://github.com/AnthonyLloyd/CsCheck/blob/master/docs/Comparison.md):
  - A `Version(major, minor, build)` that fails only when all three are equal
    shrinks to `0.0.0`, where Hedgehog stops at `249.249.249`. It took 100 million
    iterations, about 5 s on many cores.
  - For `2 * major + minor + build >= 510`, it reaches `255.0.0` by trading between
    axes.

  Strategy B handles both only with dedicated passes: Hypothesis has
  `minimize_duplicated_choices` and redistribution passes.
- **"Given enough time" is the catch.** It needs generators that produce small
  values often, and cheap tests. A needle-in-a-haystack minimum can take very long.
- **Nondeterministic failures** (parallel and concurrency tests) suit it well. A
  path-exploring shrinker must repeat each step (QuickCheck: 10 times). A random
  one just lowers its bound whenever something fails.
- **Hardly any shrinking code**, but the size measure must be designed for each
  generator, just as the choice encoding must in strategy B.

**Strategy C as a standalone choice vs. a C-inspired pass in strategy B.**
Choosing strategy C means it is *the* shrinker: there are no local passes at all,
only random search, and generators define their own size measures. Choosing
strategy B does not rule out the core idea of C, though. Strategy B already has a
size measure, since the choice list in shortlex order is one. So a **random search
pass** fits strategy B without changing any generator:

- Keep generating fresh random choice lists. Run the test only on those that are
  shortlex-smaller than the current minimum, and adopt any that still fail.
- Cap the length at the current minimum's length, so that longer candidates
  overrun at once. This is CsCheck's early abort, for free.
- Run it when the local passes reach a fixpoint, with whatever time or iteration
  budget is left. Then hand any improvement back to the local passes.

What does *not* carry over:

- CsCheck's hand-designed size measures. Shortlex on choices is a different, more
  generic notion of "smaller".
- The seed of the shrunk case. In strategy B, the shrunk choice list already plays
  that role.
- CsCheck's reliance on parallelism to make random search affordable.

A C-inspired pass would help with the cases where local passes get stuck (coupled
or trade-off values like the `Version` examples) and with nondeterministic
failures. Whether it is worth having is open. It is an optional addition after the
core passes, and does not need to be decided up front.

### Trade-off summary

|                                    | A. Rose trees                      | B. Choice sequences                    | C. Random search by size                  |
|------------------------------------|------------------------------------|----------------------------------------|-------------------------------------------|
| Where shrinking logic lives        | In every combinator                | One generic shrinker                   | None; size measure per generator          |
| Shrinking through `map` / `filter` | Good                               | Good                                   | Good                                      |
| Shrinking through `flat_map`       | Often poor                         | Good                                   | Good                                      |
| Stateful tests                     | Needs dedicated sequence shrinking | Free                                   | Free                                      |
| Shrink quality for simple types    | Precise, tailored per type         | Depends on choice encoding             | Depends on the size measure               |
| Local minima                       | Yes                                | Yes (fewer with more passes)           | No, given enough time                     |
| Cost                               | Few, targeted candidates           | Few, targeted candidates               | Many random candidates; needs cheap tests |
| Understanding a stuck shrink       | Inspect the tree                   | Inspect the shrink passes              | Not stuck, just slow                      |
| Replay / example database          | Seed + size                        | The shrunk choice list itself          | Seed of the shrunk case                   |
| Amount of code                     | Grows with every combinator        | Small core, combinators stay trivial   | Smallest; plus parallelism to be fast     |

## Designing strategy B

Notes for the case where strategy B is chosen. They come from the prototype, the source
code of the implementations above, and the ECOOP paper.

### Core types

- **Start with a plain list.** In the prototype, `Choices` is first an alias for
  `List(Int)`, so generators can be tested with literal lists and no randomness.
  Recording and replay (below) replace the alias in roadmap step 3, without
  changing the generator type.
- **Two generator outcomes are enough.** elm-microthesis uses
  `Generated { value, prng } | Rejected { reason, prng }`. Running out of choices
  is just a rejection with a reason. minithesis instead has a status ladder
  (`OVERRUN < INVALID < VALID < INTERESTING`), and elm-minithesis a `Stop` error
  type. Either way, errors are values and the property is a plain function. The
  prototype uses `Result(#(a, Choices), Rejected)` with a reason from the start.
- **Separate per-example and per-run results.** An example holds, fails or is
  discarded. A run passes, is disproven or gives up. The prototype's `Example(a)`
  and `Outcome(a)` keep them apart, so a run can never end as "discarded".
  `Discarded` is needed from the start, before `filter` and `assume` exist,
  because `draw` itself can reject.
- **The random source is a sum type**, so that "randomness during shrinking"
  cannot be expressed (elm-microthesis):
  `Random { seed, run } | Hardcoded { wholeRun, unusedPart }`. elm-minithesis's
  `seed : Maybe Seed` needs a runtime error for the same case. The prototype has
  `Random | Replay(remaining)`, with `Random` still unseeded.
- **Draw within range, and reject out-of-range replays.** When generating,
  `draw(max)` asks the PRNG for a value in `0..=max`. When replaying, a value
  greater than `max` rejects the candidate (minithesis). The prototype's first
  version wrapped values with modulo instead. Then a smaller choice is not a
  smaller value: for `draw(10)`, choice 11 is 0 but choice 10 is 10. Clamping is
  the alternative to rejecting. elm-microthesis does neither, so its
  redistribution pass, which *raises* a value, can make `int 10` return 15.
- **Cap the entropy.** Hypothesis and minithesis allow `8 * 1024` per example ("We
  cap the maximum amount of entropy a test case can use"). Beyond that, the
  example overruns. That cap is what keeps recursive generators finite.
- **The data structure for the recorded run matters.** Appending to a list is
  O(n). elm-microthesis has branches benchmarking list, array, deque and queue. In
  Gleam: prepend and reverse once (as the prototype does), or choose deliberately.

### Choice encoding

The shrinker only lowers and deletes choices, so generators must make *smaller
choices mean simpler values*. MacIver & Donaldson call this generator/reducer
co-design. It is worth doing for the library's own generators, while user
generators get the generic reducer and are expected to be "adequate".

- **Integers:** zigzag around a target (Hypothesis `zigzag_index`: indices 0, 1, 2,
  3, 4 map to 0, 1, -1, 2, -2). Both Elm ports use `from + choice(to - from)`, which
  shrinks towards `from`, not zero. Their own code marks this with a TODO.
- **Alternatives:** `one_of` / `frequency` shrink towards the first option, so list
  the simplest first.
- **Collections: a "one more?" flag before each element**, not a length up front.
  Deleting a flag plus an element chunk then removes one element, and deleting
  adjacent choices can even merge lists of lists. With a length first, every
  deletion leaves the rest misaligned, and fixing it takes O(n²) paired edits.
  Hypothesis has a pass for that, but it is slow.
- **Floats** are built from an integer choice like everything else. What needs
  care is the mapping, so that "smaller choice" means "simpler float" to a
  *human*:
  - Taking the IEEE 754 bits as the choice shrinks towards 0.0 by bit pattern.
    The smallest non-zero result is 5e-324, which looks pathological, where 1.0
    is what a reader would want (MacIver & Donaldson).
  - Scaling a choice linearly into a range gives values like 0.000123.

  Hypothesis's encoding (`internal/conjecture/floats.py`, reused by elm-minithesis
  as `lexToFloat`) is a tagged union:
  - Tag 0: the payload is a plain integer, so whole numbers are the simplest
    floats (9.0 is choice 9).
  - Tag 1: everything else, in an order chosen for simplicity. Exponents are
    reordered so that non-negative ones come first. Fraction bits are reversed,
    so that lowering the choice removes the finest fractions first, and values
    with a smaller denominator come first. The sign only breaks ties (positive
    first), and infinity and NaN come last.

  The cost is that some human-obvious steps are far apart as choices: 9.1 is
  choice 9237896145653045656. Generic passes are unlikely to find 9.0 from there
  ("quite hard for the reducer to discover on its own", says the paper), so
  Hypothesis adds its only generator-specific shrink pass for floats.
  Copy all of this rather than reinvent it, and only when garanti needs floats.
- **Generators are total.** elm-minithesis rejects `int` with `from > to`, an empty
  `one_of` or `min > max` with a reason, instead of crashing.
- **Recursion is fine inside `flat_map`, but not in arguments.** `list_of` is
  recursive, but its recursive call sits inside the `flat_map` callback, which only
  runs after a "more" flag has been drawn. So it is lazy already. A generator that
  passes *itself as an argument* is different, e.g.
  `fn expr() { one_of([map(int(), Lit), map2(expr(), expr(), Plus)]) }`. In a
  strict language such as Gleam or Elm, `expr()` is evaluated while the
  generator is being *built*, before any choice is drawn, and never terminates.
  Wrapping it as `lazy(fn() { expr() })` delays it until a choice actually
  selects that branch. Once recursion is lazy, what keeps it finite at *run* time
  is the choice of branch (e.g. `frequency` weights) and the entropy cap.
- **Typed choices** (integer, boolean, float, string, bytes, each with constraints)
  are where Hypothesis ended up, after a raw byte buffer. Plain integers are
  enough to start with.

### Sizing generated data

How large generated values get matters most for collections and recursive
structures. Take **lists**, generated with a "one more?" flag before each element:

- A fair flag (stop with probability ½, as in `draw(1)`) gives lists that
  average one element, and practically never 200.
- Reading the flag with `draw(size)` instead, where 0 still means stop, makes the
  average length `size`. With `size = 50`, about 2% of lists reach 200 elements.
  Shrinking is unaffected: lowering a flag to 0 still ends the list.

Prior art:

- **QuickCheck** threads an implicit size through all generators (`sized`,
  `resize`, `scale`). `listOf` picks a length uniformly in `0..size`. The runner
  grows the size during a run: 0, 1, …, 99 with the defaults, cycling with more
  tests. Early examples are therefore small and cheap. Recursive generators
  conventionally shrink the size for subtrees.
- **Hypothesis** has no global size. `lists` takes `min_size` and `max_size`, and
  derives an average of `min(max(2·min, min + 5), (min + max) / 2)`, i.e. 5 by
  default. It draws a "one more?" boolean with probability `1 - 1/(1 + average)`
  (5/6), refined numerically for a finite max. The flag is forced below `min_size`
  and at `max_size`, but still recorded. Elements rejected by a filter are marked
  so that the shrinker can delete them.
- **minithesis** uses a fixed `weighted(0.9)`, which averages 9 elements.

Open for garanti: an implicit growing size, explicit bounds per generator, or both.
Whether `list_of` takes `min`/`max` from the start. How recursion is bounded (a
shrinking size, the entropy cap, or both).

### The shrinker

- **One acceptance rule:** a candidate is accepted only if it generates, still
  fails, *and* is shortlex-smaller (see [strategy B](#b-choice-sequences--internal-shrinking-hypothesis--our-leaning)).
  That alone guarantees termination (elm-microthesis `tryShrink`). Comparing from
  the left (rather than from the right) is chosen because it follows the time order
  of generation, and early choices affect more of the value. A candidate that is
  rejected or passes is simply not accepted. (The prototype has no shortlex check,
  and stops at the first rejected candidate.)
- **Core passes (minithesis), repeated until a full round changes nothing, each
  walking backwards** ("later bits tend to depend on earlier bits"):
  1. delete chunks of 1–8 choices. If that fails, also try decrementing the choice
     before the chunk, which fixes "draw a length, then elements",
  2. replace blocks of 2–8 choices with zeros,
  3. binary-search each choice downwards.
- **Extras** ("just showing off cool shrinker tricks"): sort short ranges, swap
  out-of-order pairs, *redistribute* value between nearby pairs. The last fixes
  local minima like `[41, 60]` for `sum <= 100`, which the core passes cannot
  leave. Hypothesis also lowers duplicated or related integers together.
- **Deterministic passes, not luck.** The prototype's shrinker lowers every
  choice to a random value, within a budget of 20 attempts. For `is_three_digits`
  on `int_range(100, 1100)` it stops at values like 1006, 1025 or 1058 instead of
  1000. Even from 1001, only one candidate in 902 hits 1000, and a property that
  fails only when three choices are equal needs about `1/(n+1)^2` luck per
  attempt. Binary search per choice needs about `log2(c)` attempts and no luck.
  Hypothesis's integer shrinker tries 0 and 1,
  then shifts bits off, then uses `find_integer`: a linear scan of 1..4, then
  exponential probing, then bisection. That is cheap when the answer is small,
  which it usually is. The
  [shrinking challenge](https://github.com/jlink/shrinking-challenge) gives a
  ready-made benchmark for before/after numbers.
- **The shrink plan as data.** elm-microthesis describes each concrete shrink
  attempt as a value, e.g. "delete 2 choices at index 5" or "binary-search the
  choice at index 3". For the current choice list it builds the full list of such
  attempts up front (chunk sizes 1, 2, 4, 8, back to front), and folds over it,
  skipping attempts that no longer fit as the list shrinks. Each pass is testable
  on its own, and a shrink history (value, choices, pass name) comes for free.
  elm-minithesis exposes that history as `showShrinkHistory`.
- **Pass order drives cost.** In the SymPy experiment (see strategy B), Hypothesis
  spent its effort on lexicographic polishing while the sequence could still get
  shorter. Running deletions to a fixpoint before
  the lexicographic passes is a reasonable first heuristic.
- **Later, a random search pass** inspired by strategy C, for when the local
  passes are stuck. See
  [strategy C as a standalone choice vs. a C-inspired pass](#c-random-search-by-size-cscheck).
- **Later, structure-aware passes.** Hypothesis records where each generator call
  starts and ends in the sequence ("spans"). Deleting or zeroing a whole span is
  O(n) attempts instead of O(n³) blind ones, much like hierarchical delta
  debugging uses a grammar. When a zeroed span consumes fewer choices, the pass
  retries with exactly that many. In a combinator library, `flat_map` is a natural
  place to record spans.
- **A cache is optional.** minithesis keeps a trie from choice sequences to
  outcomes to skip repeats and known overruns. Neither Elm port has one.

### What counts as the same failure

While shrinking, a candidate may fail for a *different reason*, and the search
then reduces a different bug ("shrinkers are fuzzers"). Integrated shrinking
removes invariant violations as one cause, but a property with several assertions
can still slip. Hypothesis tracks an `interesting_origin` per failure (roughly
exception type and location) and shrinks each separately, and the ECOOP
experiments used "same exception type and line number". minithesis treats any
exception as the same failure. For garanti the open question is: any `Fail`, the
same summary, or panic vs. `Fail`?

**Flaky tests hurt every reducer.** Hypothesis replays the final example, and
fails loudly when the result is not reproducible:

- `FlakyFailure`: "Hypothesis … produces unreliable results: Failed on the first
  call but did not on a subsequent one". It also covers the case where a replay
  fails with a *different* error. Its docstring lists the usual causes: the
  function depends on external state (e.g. its own random number generator), deep
  recursion, or timing sensitivity.
- `FlakyStrategyDefinition`: "Inconsistent data generation! … Is your data
  generation depending on external state?". Here the *generator*, not the test,
  is non-deterministic.
- A separate "Unreliable test timings!" report covers a test that exceeded its
  deadline once but not on replay.

Both point the user at the likely cause, a non-pure function under test or a
non-pure generator, instead of presenting a counterexample that does not
reproduce. A replay check like this is cheap in strategy B, since the final choice
list is already at hand. For garanti, the remaining question is whether
non-reproducibility should be its own kind of failure in the report.

## Question 2: public API for properties

Open. Background:

- `use x <- property.for_all(gen)` inside a regular `Test`, returning an
  `AssertionResult`. It composes with `expect.*` and `expect.all`. `use` turns the
  rest of the block into a callback, so this is
  `property.for_all(gen, fn(x) { … })`. The body is therefore a
  `fn(a) -> AssertionResult` that `for_all` can call as often as it likes. The
  matchers know nothing about shrinking. They are the oracle that `for_all` asks
  "does this value still fail?" for every shrink candidate, and the final report
  can show the matcher's own diff for the shrunk value.
- **Pitfall: two `for_all` in a row.** `use a <- property.for_all(g1)` followed by
  `use b <- property.for_all(g2)` nests one property loop inside another. That
  gives 100 × 100 runs, and the outer shrinker sees only the inner `for_all`'s
  verdict. There are two fixes:
  - Combine the generators first, as in `for_all(tuple2(g1, g2))`.
  - Make the binding build a single generator that runs once. That is the next
    bullet.

  F# shows the same split. A computation expression's `let! x = m` desugars to
  `builder.Bind(m, fun x -> …)`, which is the same rewrite as Gleam's `use`.
  FsCheck's `gen { let! … }` composes generators (`Bind` = `flat_map`). Hedgehog's
  `property { let! x = gen … }` (in Haskell, `x <- forAll gen` inside
  `property`) binds a generator inside one property that is generated, run and
  shrunk as a whole.
- Gleam has no default arguments, so a `for_all_with(config, gen, body)` would
  take the number of examples and the seed, and `for_all` would call it with the
  defaults. The prototype's `for_all` calls its loop with a fixed 20.
- **Drawing inside the test** (minithesis `test_case.any(gen)`, Hypothesis
  `data.draw`): later draws can depend on earlier results. In Gleam this could be
  `use x <- draw(tc, gen)`.
- **Tests as values** (both Elm ports): `test(label, gen, predicate)` builds a
  value, and `run(seed, test)` returns
  `Passes | FailsWith(a) | FailsWithShrinks(…) | Unsatisfiable(…)`. That is pure and
  easy to test. elm-minithesis's bridge to elm-test multiplies the two run counts,
  a problem garanti avoids by integrating natively.
- A `generator.sample(gen, seed)` for looking at generated values while writing
  generators (elm-minithesis `Fuzz.example`).

## Question 3: discards and "gave up"

**Why discard at all?** The function under test often has a precondition. It may
panic on 0 or negative numbers, or on an empty string, or require a prime. A
property should only be checked on valid input, so invalid generated input must
be either avoided or thrown away. There are two quite different situations:

- **The generator is mostly right.** For example "any int except 0", or "any
  non-empty string". Discarding the rare invalid case with
  `filter(gen, pred)` or `assume(cond)` inside the test is cheap and keeps the
  property readable. The cost is a few wasted attempts.
- **The generator is mostly wrong.** For example `filter(int(0, 1_000_000), is_prime)`.
  Only about 7.8% of those integers are prime, so most attempts are wasted.
  - With minithesis's 3 tries per filter, about 78% of test cases are still
    rejected.
  - With a 10× attempt budget (below), the run then finds far fewer than the
    intended 100 valid examples, or none, and has to stop.

  Construction is the fix here, rather than filtering: generate an index and map
  it to the n-th prime, or `map(int, fn(x) { x * 2 })` for even numbers.
  Construction never discards. In strategy B it also shrinks within the invariant,
  since the generator is replayed: a constructed prime shrinks to a smaller prime.

**Two ways to discard,** both part of the PBT library, not of Gleam:

- `filter(gen, pred)` is a generator combinator. It discards on the *generator*
  side, one generated value at a time.
- `assume(cond)` is called inside the *property*, and discards the current
  example when `cond` is false. Prior art: Hypothesis `assume`, minithesis
  `test_case.assume`, QuickCheck's `==>`. It can express preconditions that relate
  several generated values, e.g. `assume(a != b)`, which no single generator's
  `filter` can.

In garanti, `assume` would need a way for a property to say "discard" rather than
pass or fail, e.g. `use <- property.assume(b != 0)`. `AssertionResult` has no
such variant today, and since that type is public, the property body could
return a wrapper instead, such as `Checked(AssertionResult) | Discarded`. For two
`use <- assume(…)` in a row to compose, `assume` takes and returns the wrapper,
so the last line of the body has to be wrapped too. Ways around that:

- two variants of `for_all`, one for bodies returning `AssertionResult`,
- a small helper that lifts an `AssertionResult` into the wrapper,
- Hypothesis's way: `assume` aborts the example with a marker panic, caught per
  example like any other panic. The body stays an `AssertionResult`, at the cost
  of control flow that is unusual in Gleam.

So the open question is what garanti does when discards dominate: silently run
fewer examples, fail as "gave up", or warn.

Background:

- minithesis: `assume` / `reject` and `filter` (after 3 tries) mark a case
  invalid. A run stops after `max_examples` valid cases or `10 × max_examples`
  attempts. It fails as `Unsatisfiable` only if *no* case was valid, so a run that
  reached, say, 20 valid cases passes quietly. The Elm ports use the same `10 ×`
  limit, and their `filter` rejects at once.
- Hypothesis has a *health check*, `filter_too_much`, for "when the test is
  filtering out too many test cases, either through use of `assume` or `.filter`".
  It turns the heavy-filtering case into an explicit failure.
- Both Elm ports record a **reason** per rejection and report
  `Unsatisfiable { mostCommonRejections }`, so users see *why* (`"filter"` vs.
  `"int: from > to"`).

## Question 4: reporting counterexamples and seeds

**What a failure report is for.** "Property `reverse_is_involution` failed" says
almost nothing. A useful report gives the user:

- **A concrete counterexample**: the generated input that made the property fail.
- **A shrunk one**, with everything irrelevant removed. A stateful test should not
  report "add 1, then subtract 2, then add 1, then …" when two steps are enough to
  trigger the bug. The smaller the example, the closer it points at the cause.
- **What the property said about it**: the `AssertionResult` from the matcher,
  with its expected/actual/diff, or the panic.
- **A way to reproduce it** exactly (see below).

The goal is that the user can turn the counterexample straight into an ordinary
example-based `Test`, a *regression test*, and fix the bug against it. They should
not have to rely on randomness to find the same failure again. Some failures are
rare, and the run that found one may simply have been lucky. So **every counterexample is valuable information,
and should never be thrown away or assumed to be easy to find again**. That is
also the argument for an example database (roadmap step 8), which replays
previously failing cases first.

Open: what exactly garanti prints, and in which form. Background:

- minithesis replays the final choices once more, calling the test directly, so
  that it prints every top-level drawn value and the user's own exception
  propagates. It does not check anything, though: if the replay happens to pass,
  the run ends quietly and the failure is lost. Hypothesis's final replay is where
  it detects flakiness (see
  [What counts as the same failure](#what-counts-as-the-same-failure)).
- CsCheck prints a seed for the *shrunk* case, plus counts:
  `(12 shrinks, 3,456 skipped, 4,000 total)`. In strategy B, the *shrunk choice
  list* plays that role. The original list came from a seed, but the shrunk one is
  an edited list that no seed may produce. So the seed reproduces the original
  failure, and the list is what reproduces the minimal one. Replaying the list
  needs no PRNG at all, so it also works across targets, where the BEAM and JS
  PRNGs (roadmap step 7) produce different sequences from the same seed. Reports
  and the example database should therefore keep the list, not just the seed.
- An optional shrink history (elm-minithesis) helps users tune generators. See also
  Hypothesis's guide
  ["Strategies that shrink"](https://github.com/HypothesisWorks/hypothesis/blob/master/guides/strategies-that-shrink.rst).
- The reduced result is only locally minimal, and the report should not claim
  otherwise.
- **Small integer lists print as text.** A generic reporter would print a
  counterexample with Gleam's `string.inspect` (the formatting `echo` also uses),
  as garanti's failure messages already do. `string.inspect` shows any `List(Int)`
  whose values are all printable character codes as a *charlist* (Erlang's
  representation of a string as a list of character codes), on both targets.
  A shrunk counterexample such as `[101]` (for `sum(xs) <= 100`) is printed as `charlist.from_string("e")`. Shrunk counterexamples are typically lists of small
  numbers, so this will happen often. Options: an optional `show` function per
  property, or a formatting fallback in the reporter.

## Sources

Verified against the source code on 2026-10-18.

- **QuickCheck** 2.19.0.0: `Test.QuickCheck.Gen` (`listOf`, `sized`, `resize`,
  `scale`), `Test.QuickCheck.Test` (`stdArgs`, `computeSize`).
  <https://hackage.haskell.org/package/QuickCheck>
- **Hypothesis**, `master`, `hypothesis/src/hypothesis/`: `internal/conjecture/`
  `utils.py` (`many`, `_calc_p_continue`), `choice.py` (typed choices,
  `zigzag_index`), `shrinker.py` (`sort_key`, passes), `shrinking/integer.py`,
  `junkdrawer.py` (`find_integer`), `engine.py` (`BUFFER_SIZE`,
  `interesting_origin`), `floats.py` (float encoding); `strategies/_internal/collections.py`;
  `_settings.py`; `errors.py` (`Flaky`, `FlakyFailure`, `FlakyStrategyDefinition`);
  `core.py` (the "unreliable results" and "Unreliable test timings!" messages).
  <https://github.com/HypothesisWorks/hypothesis>
- **minithesis**, `master`: `README.md`, `minithesis.py`.
  <https://github.com/DRMacIver/minithesis>
- **elm-minithesis**, `master`: `README.md`, `src/Minithesis.elm`, `Minithesis/Fuzz.elm`,
  `Fuzz/Internal.elm`, `TestCase.elm`, `RandomRun.elm`, `Stop.elm`,
  `TestingState.elm`, `TestingState/Internal.elm`, `Test/Minithesis.elm`.
  <https://github.com/Janiczek/elm-minithesis>
- **elm-microthesis**, `master`: `src/Microthesis.elm`, `Microthesis/Generator.elm`,
  `PRNG.elm`, `RandomRun.elm`, `Shrink.elm`; branch names via the GitHub API.
  <https://github.com/Janiczek/elm-microthesis>
- **qcheck** (Gleam), `main`: `README.md`, `src/qcheck.gleam` (`Generator`, `Tree`).
  <https://github.com/mooreryan/gleam_qcheck>
- **QuickCheck 1.2.0.1** docs: the `Arbitrary` class has no `shrink`.
  <https://hackage.haskell.org/package/QuickCheck-1.2.0.1/docs/Test-QuickCheck.html>
- **CsCheck**, `master`: `README.md`, `docs/Why.md`, `docs/Comparison.md`,
  `CsCheck/Gen.cs` (`Size`, `GenInt`, `GenList`), `CsCheck/Check.cs` (`SampleAsync`).
  <https://github.com/AnthonyLloyd/CsCheck>
- D. R. MacIver & A. F. Donaldson, "Test-Case Reduction via Test-Case Generation:
  Insights From the Hypothesis Reducer", ECOOP 2020, DOI 10.4230/LIPIcs.ECOOP.2020.13.
  <https://drmaciver.github.io/papers/reduction-via-generation-preview.pdf>
- D. R. MacIver, "Integrated vs type based shrinking", 2016-12-05.
  <https://hypothesis.works/articles/integrated-shrinking/>
- A. Lloyd, "The happy state of property-based testing in C#", 2024-07-07.
  <https://anthonylloyd.github.io/blog/2024/07/07/cscheck-happy-state>
- S. Andjelkovic, "The sad state of property-based testing libraries".
  <https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html>
- jlink, shrinking challenge. <https://github.com/jlink/shrinking-challenge>
