# Key points of a PBT design for garanti

A concrete, step-by-step sketch of how to add property-based testing (PBT) to garanti.
Each step is useful on its own and builds on the previous one. The early steps
start with the simplest thing that works, and later steps replace it once there is
a reason to.

Decisions marked ★ are places where several reasonable designs exist. One has
been picked only to keep this simplified explanation of the concepts concrete;
it is not a recommendation that settles the question. The alternatives and the
trade-offs are in the companion document, `property-based-testing.md`.

Code samples come from a small hand-written prototype (`src/propp.gleam`).
Its git history follows steps 1 to 5 in order. It is a sketch to make the ideas
concrete, not code for garanti. Where the prototype takes a shortcut, the text
says so.

## The idea in one paragraph

A property is a function that should hold for *all* inputs of some kind, e.g.
"reversing a list twice gives the original list". Garanti generates many random
inputs, runs the property on each, and if one fails, *shrinks* it to a minimal
failing input and reports that. Generators never call a random function directly.
They read from a **list of integer "choices"**. When generating, the choices come
from a random source. To shrink, garanti edits the list of choices a failing
example used (deleting and lowering choices) and runs the same generator on it
again. ★ This means every generator gets shrinking for free, and every shrunk
value is one the generator could actually have produced.

## How it fits into garanti

- A property is an ordinary `Test`, so suites, focus, the runner and the reporter
  stay unchanged.
- The property body returns an `AssertionResult`, so all `expect.*` matchers and
  their diffs work inside properties.
- Panics are caught *per generated example* (like `executor.run_catching` does per
  test), so panicking inputs can be shrunk too.

## Step 1: generators read a list of choices

A generator is a function from a list of choices to a value plus the remaining
choices, or a rejection:

```gleam
pub type Choices =
  List(Int)

pub type Generator(a) {
  Generator(run: fn(Choices) -> Result(#(a, Choices), Rejected))
}

pub type Rejected {
  Rejected(reason: String)
}
```

**`draw(max)`** is the only primitive that reads a choice. Everything else is
built from it:

```gleam
fn draw(max: Int) -> Generator(Int) {
  Generator(fn(choices) {
    case choices {
      [first, ..rest] -> Ok(#(first % { max + 1 }, rest))
      [] -> Error(Rejected("No more random stuff"))
    }
  })
}

fn map(ga: Generator(a), mk_b: fn(a) -> b) -> Generator(b) {
  Generator(fn(choices) {
    use res <- result.try(ga.run(choices))
    Ok(#(mk_b(res.0), res.1))
  })
}

fn int_range(min: Int, max: Int) -> Generator(Int) {
  map(draw({ max - min }), int.add(_, min))
}
```

- `Choices` is only an alias for now. Step 3 turns it into a type of its own, so
  the generator type and all signatures stay the same.
- **A literal list is all a test needs.** `int_range(10, 20).run([1, 2, 3])` gives
  `Ok(#(11, [2, 3]))`, with no randomness and no seed.
- The modulo is a shortcut. It makes every list valid, but a smaller choice is not
  always a smaller value. That does not matter until shrinking (step 3).
- Watch the bounds: `draw(max)` gives `0..=max`, so the modulo is `max + 1`. (The
  prototype's first version had `% max`.)
- Every rejection carries a **reason**, so that "gave up" can say why. Have it
  from the start, it costs nothing.
- Generators are **total**: bad parameters (e.g. `int_range(10, 1)`, empty
  `one_of`) reject with a reason instead of panicking. (The prototype's
  `int_range` doesn't check its bounds yet.)

## Step 2: running properties

```gleam
// Sketch of the API.
Test("reverse is an involution", fn() {
  use xs <- property.for_all(generator.list_of(generator.int_range(-100, 100)))
  expect.to_be_equal(list.reverse(list.reverse(xs)), xs)
})
```

- ★ `property.for_all(gen, body)` returns an `AssertionResult`, so it lives inside
  an ordinary `Test`. Gleam has no default arguments, so
  `property.for_all_with(config, gen, body)` takes the number of examples
  (★ default 100) and the seed, and `for_all` calls it with the defaults.
- It runs the body on each generated value, and catches panics per example. On the
  first failure it shrinks (step 4), then reports (step 8).

The prototype starts with a property of type `fn(a) -> Bool`, and fills a fresh
list with random choices for each example:

```gleam
fn random_choices(n: Int) -> Choices {
  list.repeat(Nil, n) |> list.map(fn(_) { int.random(1_000_000) })
}
```

**Two result types: one per example, one per run.** An example can hold, fail,
or be discarded because the generator rejected. A run passes, is disproven, or
gives up. Keeping them apart means a run can never end as "discarded".
`Discarded` is needed from the start, before `filter` and `assume` exist,
because `draw` itself can reject (the list ran out):

```gleam
pub type Example(a) {
  Holds
  Counterexample(a, consumed: List(Int))
  Discarded(Rejected)
}

pub type Outcome(a) {
  Passed(passed: Int)
  Disproven(value: a, passed: Int, choices: List(Int))
  GaveUp(Rejected)
}
```

Treating a rejection as "holds" is tempting, but it is exactly the silent pass
that step 6 warns against.

Running one example returns the choices the generator consumed together with a
counterexample. Running the generator on them gives the same value again, so a
reported failure can already be replayed:

```gleam
fn check1(
  choices: Choices,
  gen: Generator(a),
  prop: Property(a),
) -> Example(a) {
  case gen.run(choices) {
    Ok(#(a, rest)) ->
      case prop(a) {
        True -> Holds
        _ -> {
          // assumes we only ever take items from the front of choices
          // and return a proper suffix
          let consumed =
            list.take(choices, list.length(choices) - list.length(rest))
          Counterexample(a, consumed)
        }
      }
    Error(r) -> Discarded(r)
  }
}
```

Switching the property to `AssertionResult` and catching panics per example
changes only `check1`.

## Step 3: recording choices instead of pre-filling them

Shrinking (step 4) means lowering and deleting choices, then running the
generator on the result. Three shortcuts from steps 1 and 2 get in the way:

- With modulo, lowering a choice can *raise* the value: for `draw(10)`, choice 11
  is 0 but choice 10 is 10.
- The pre-filled list has to guess its length up front (10 in the prototype).
  A generator that needs more runs out.
- The consumed choices are worked out from the length of the rest, which assumes
  that generators only ever take from the front.

The fix is to record choices as they are drawn, from one of two sources. The
`Choices` alias becomes a type of its own, and the generator type stays as it is:

```gleam
pub opaque type Choices {
  Choices(source: Source, recorded: List(Int))
  // reversed
}

type Source {
  Random                       // generating: draw and record
  Replay(remaining: List(Int)) // shrinking/replay: no randomness at all
}
```

`draw` now draws within range when generating, and when replaying it rejects a
value greater than `max` (★) or an exhausted list:

```gleam
fn draw(max: Int) -> Generator(Int) {
  Generator(fn(choices) {
    case choices.source {
      Random -> {
        let value = int.random(max + 1)
        Ok(#(value, Choices(..choices, recorded: [value, ..choices.recorded])))
      }
      Replay([choice, ..]) if choice > max -> Error(Rejected("choice > max"))
      Replay([choice, ..rest]) ->
        Ok(#(
          choice,
          Choices(Replay(rest), recorded: [choice, ..choices.recorded]),
        ))
      Replay([]) -> Error(Rejected("No more choices"))
    }
  })
}
```

- Only `draw`, `check1` and the loop change. `map` and `int_range` stay as they
  are. `check1` now returns `list.reverse(recorded)` with a counterexample.
- `Choices` is opaque, so tests that passed literal lists now need a small
  constructor such as `replay(list)`.
- `Random` stays unseeded (`int.random`) for now. Generators only ever see
  `Choices`, so a seeded source (step 7) can replace it without touching any
  generator.
- A cap on the number of choices per example (e.g. 8 × 1024) rejects runaway
  generation, now that the list no longer has a fixed length. (Not in the
  prototype.)

## Step 4: shrinking

Shrinking works on the recorded choice list, never on values. A candidate list is
run through the same `check1` as a generated example, only with
`Replay(candidate)` as the source. If it gives a `Counterexample`, the candidate
is accepted and shrinking continues from its consumed choices. Nothing in this is
specific to any generator.

The shrinker is a self-contained function, so the first one can be crude and
replaced later. The prototype's tries random candidates, each choice lowered to a
random value in `0..=c`, within a budget of attempts:

```gleam
let candidate = list.map(choices, fn(v) { int.random(v + 1) })
case check1(Choices(Replay(candidate), []), gen, prop) {
  Holds -> shrink(current, gen, prop, choices, budget - 1)
  Counterexample(s, consumed) ->
    shrink(s, gen, prop, consumed, budget - 1)
  Discarded(_) -> #(current, choices)
}
```

It shrinks, but the result depends on luck and budget: `int_range(100, 1100)` with
`is_three_digits` (`v < 1000`) and a budget of 20 stops at values like 1006,
1025 or 1058 instead of 1000. Even from 1001 (choice 901), only one candidate in
902 hits 1000. A property that
fails only when three choices are equal needs about `1/(n+1)^2` luck per attempt.
The real shrinker therefore uses deterministic passes:

- **Acceptance rule:** a candidate list is accepted only if the generator accepts
  it, the property still fails, *and* it is *shortlex-smaller*. Shortlex means
  shorter first, then compared element by element from the left like words in a
  dictionary: `[5] < [0, 0] < [0, 0, 7] < [0, 1, 0] < [1, 0, 0]`. This rule alone
  guarantees that shrinking terminates. (The prototype has no such rule, so a
  candidate equal to the current list counts as progress.)
- A candidate that is rejected or passes is simply not accepted, and the next
  one is tried. (The prototype stops shrinking at the first rejected candidate.)
- **Passes**, repeated until a full round changes nothing, each walking from the
  end of the list backwards. ★ Deletions come first, because they are cheap and
  remove the most:
  1. delete chunks of 8, 4, 2 and 1 choices. If a deletion fails, also try it
     with the choice just before the chunk decremented,
  2. replace blocks of 8, 4 and 2 choices with zeros,
  3. lower each choice by binary search towards 0.
- Each attempt (e.g. "delete 2 choices at index 5") is a value. The plan for a
  round is a list of attempts, which keeps passes testable, and gives a shrink
  history for debugging generators.

Later, if needed:
- passes that move value between nearby choices (so `sum(xs) <= 100` shrinks to
  `[101]` rather than stopping at `[41, 60]`),
- a random-search pass for when the others get stuck,
- passes aware of each generator call's start and end in the list.

## Step 5: composed generators

`flat_map` and `map2` are not needed until the first generator for a domain
type. Like `map`, they contain no shrinking code:

```gleam
fn flat_map(ga: Generator(a), mk_gb: fn(a) -> Generator(b)) -> Generator(b) {
  Generator(fn(choices) {
    use #(a, rest) <- result.try(ga.run(choices))
    mk_gb(a).run(rest)
  })
}

fn map2(
  ga: Generator(a),
  gb: Generator(b),
  mk_c: fn(a, b) -> c,
) -> Generator(c) {
  use a <- flat_map(ga)
  use b <- map(gb)
  mk_c(a, b)
}
```

Each field of a composed value reads from the same choice list, in order. The
prototype's example is a bar, with a bug: it thinks 16 is old enough for alcohol.
A drink order is a person (an age) and a drink:

```gleam
// Smaller choice, simpler value: Water is the simplest drink
fn drinks() -> Generator(Drink) {
  map(draw(3), fn(choice) {
    case choice {
      0 -> Water
      1 -> Beer
      2 -> Wine
      _ -> GT
    }
  })
}

// Age shrinks towards 10.
fn people() -> Generator(Person) {
  map(int_range(10, 30), Person)
}

fn drink_orders() -> Generator(DrinkOrder) {
  map2(people(), drinks(), DrinkOrder)
}

fn check_bar() {
  use drink_order <- for_all(drink_orders())
  only_adults_are_served_alcohol(drink_order)
}
```

The shrinker from step 4, unchanged, shrinks a failure to a 16-year-old ordering
a beer, choices `[6, 1]`, with no shrinking code for drink orders.

The library's own generators follow one rule: **a smaller choice means a simpler
value**, because shrinking only lowers and deletes choices.

- `int_range(min, max)`: choice 0 is the value closest to zero, then alternating
  outwards (0, 1, -1, 2, -2, …). ★ (The prototype's `int_range` simply shrinks
  towards its lower bound.)
- `bool`, `constant`, `tuple2`/`map2`…, `one_of` and `frequency`, which shrink
  towards their *first* alternative, so put the simplest one first.
- `list_of(gen)`: draws a "one more?" flag before each element. ★ Deleting a
  flag + element then removes exactly one element. Sketch (not in the prototype):

  ```gleam
  pub fn list_of(g: Generator(a)) -> Generator(List(a)) {
    use more <- flat_map(draw(1))
    case more {
      0 -> constant([])
      _ -> {
        use x <- flat_map(g)
        use xs <- map(list_of(g))
        [x, ..xs]
      }
    }
  }
  ```

  The real version takes an average length (★ default 5) and optional
  `min`/`max`, and stops with probability `1 / (1 + average)` per flag. The
  fair flag in the sketch averages only one element.
- `lazy(fn() { gen() })`, for recursive generators that refer to themselves in
  arguments (e.g. an expression tree via `one_of`/`map2`). Recursion inside a
  `flat_map` callback, as in `list_of`, is already lazy.
- `sample(gen, seed)`, which returns a few values for eyeballing a generator.
- Floats are left out of the first version.

## Step 6: discarding invalid input

The code under test often has preconditions: it panics on 0, needs a non-empty
string, or needs a prime. The `Discarded` outcome from step 2 is already there.
This step adds two ways to produce it:

- `filter(gen, pred)` on the generator side.
- `assume(cond)` inside the property, e.g. `use <- property.assume(a != b)`. ★
  Rather than a new variant of the public `AssertionResult`, the property body
  returns a wrapper such as `Checked(AssertionResult) | Discarded`. How a body
  without `assume` avoids the wrapping is open.

Rules:

- Discards don't count as examples. (The prototype gives up at the first one.)
- ★ After 10 × the requested number of attempts, the property fails with
  "gave up", listing the most common rejection reasons, if far fewer valid
  examples than requested were found. It does not quietly pass with too few.
- The docs steer users towards **constructing** valid values over filtering. Only
  about 8% of integers below a million are prime, so `filter(int_range(0, 1_000_000), is_prime)` wastes
  most attempts. Mapping an index to the n-th prime never discards, and it shrinks
  to smaller primes.

## Step 7: a seedable random number generator

This can come this late because only the `Random` branch of `draw` and the runner
see the random source. With deterministic shrink passes, only generation needs
randomness.

- An opaque `Seed` type with `next(seed, max) -> #(Int, Seed)`, behind
  `@external`, in the same way as `run_catching`. The source becomes
  `Random(seed: Seed)`.
- BEAM: `rand:seed_s/2` and `rand:uniform_s/2` (purely functional).
- JS: a small seedable PRNG of its own (e.g. mulberry32), since `Math.random`
  cannot be seeded.
- ★ The same seed gives the same sequence *within* a target. BEAM and JS do not
  need to agree.

## Step 8: reporting and replay

A report should let the user turn the failure straight into a regression test:

- the **shrunk counterexample**, and the original one,
- the property's own `AssertionResult` (expected/actual/diff) or the panic,
- the **shrunk choice list**. It reproduces the minimal case exactly, needs no
  seed or PRNG, and so works on both targets. The seed is printed too, for the
  original run,
- the number of examples run and shrink steps taken.

The prototype's `Disproven(DrinkOrder(Person(16), Beer), 5, [6, 1])` already has
the shrunk value, the passed count and the choice list.

Further rules:

- **Replay check:** the final choice list is replayed once more. If it no longer
  fails, the property is reported as **flaky** (the test or the generator is
  probably not pure) instead of showing a counterexample that does not reproduce.
- ★ While shrinking, a candidate counts as "the same failure" only if it fails in
  the same way (same failure summary, and panic vs. `Fail`), so that shrinking
  doesn't drift to a different bug.
- Small integer lists are formatted as lists, not as charlists, which is what
  `string.inspect` gives for `[101]`. A property can supply its own `show`
  function.
- **Example database:** the failing choice list is stored per property (e.g. in a
  file under the project) and replayed first on the next run, until it passes.
  Counterexamples are too valuable to lose to the randomness of the next run.

## Step 9: laws and metamorphic tests

Thin helpers on top of `for_all`:
- `roundtrip(gen, encode, decode)`,
- `idempotent(gen, f)`,
- `commutative(gen, op)`,
- invariance under permutation,
- `equivalent_to(gen, f, reference_impl)`,
- `metamorphic(gen, transform, relation)`, which relates `f(x)` to
  `f(transform(x))`.

## Step 10: stateful (model-based) testing

Commands, each with `precondition`, `next_state` (on a model), `run` (on the real
system) and `postcondition`. A command sequence is just a generated list whose
next command depends on the model state (via `flat_map`). Shrinking it needs nothing
new, because deleting choices deletes commands, and preconditions are re-checked
on replay.

## Step 11: extras

- Coverage requirements, e.g. `cover(10%, "empty list")`, and `classify`/`label`
  statistics.
- Targeted PBT: the property reports a score, and the runner tweaks choices to
  maximise it.
- Parallel/linearizability testing (BEAM).
- Floats, with an encoding where whole numbers are the simplest values.

## What the prototype showed

- A plain list of integers is enough to write and test generators and to run
  properties. Recording and `Replay` are only needed once shrinking starts.
- The choice list, `Replay` and a function that runs one example are enough to
  shrink any generator, including a domain type composed from several fields.
- The random source is an implementation detail of `draw`, so seeding can wait.
- The shrinker is the weak part. It is self-contained, so it can be improved
  without touching generators or the runner.

---

★ Several reasonable designs exist at this point. One was picked only to keep
this explanation concrete. See `property-based-testing.md` for the alternatives
and the trade-offs.
