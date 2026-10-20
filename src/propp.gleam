import gleam/int
import gleam/list
import gleam/result

pub opaque type Choices {
  Choices(source: Source, recorded: List(Int))
  // reversed
}

type Source {
  Random
  Replay(remaining: List(Int))
}

pub type Generator(a) {
  Generator(run: fn(Choices) -> Result(#(a, Choices), Rejected))
}

pub type Rejected {
  Rejected(reason: String)
}

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

fn map(ga: Generator(a), mk_b: fn(a) -> b) -> Generator(b) {
  Generator(fn(choices) {
    use res <- result.try(ga.run(choices))
    Ok(#(mk_b(res.0), res.1))
  })
}

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

fn int_range(min: Int, max: Int) -> Generator(Int) {
  map(draw({ max - min }), int.add(_, min))
}

type Property(a) =
  fn(a) -> Bool

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

fn check1(
  choices: Choices,
  gen: Generator(a),
  prop: Property(a),
) -> Example(a) {
  case gen.run(choices) {
    Ok(#(a, Choices(_, recorded))) ->
      case prop(a) {
        True -> Holds
        _ -> {
          Counterexample(a, list.reverse(recorded))
        }
      }
    Error(r) -> Discarded(r)
  }
}

fn check_loop(
  gen: Generator(a),
  prop: Property(a),
  times_left: Int,
  passed: Int,
) -> Outcome(a) {
  case times_left {
    0 -> Passed(passed)
    n -> {
      case check1(Choices(Random, []), gen, prop) {
        Holds -> check_loop(gen, prop, n - 1, passed + 1)
        Counterexample(v, consumed) -> {
          let #(s, smaller) = shrink(v, gen, prop, consumed, 20)
          Disproven(s, passed, smaller)
        }
        Discarded(r) -> GaveUp(r)
      }
    }
  }
}

fn shrink(
  current,
  gen,
  prop,
  choices: List(Int),
  budget: Int,
) -> #(a, List(Int)) {
  case budget {
    0 -> #(current, choices)
    _ -> {
      // this is a nondeterministic way to find smaller candidates, YOLO
      let candidate = list.map(choices, fn(v) { int.random(v + 1) })
      case check1(Choices(Replay(candidate), []), gen, prop) {
        Holds -> shrink(current, gen, prop, choices, budget - 1)
        Counterexample(s, consumed) ->
          shrink(s, gen, prop, consumed, budget - 1)
        Discarded(_) -> #(current, choices)
      }
    }
  }
}

fn for_all(gen: Generator(a), prop: Property(a)) {
  check_loop(gen, prop, 20, 0)
}

fn is_three_digits(v) {
  v < 1000
}

fn check_three_digits() {
  use number <- for_all(int_range(100, 1100))
  is_three_digits(number)
}

// A bar. The bar is the code under test, and it has a bug: it thinks
// 16 is old enough to drink alcohol

pub type Drink {
  Water
  Beer
  Wine
  GT
}

pub type Person {
  Person(age: Int)
}

pub type DrinkOrder {
  DrinkOrder(person: Person, beverage: Drink)
}

fn is_alcoholic(drink: Drink) -> Bool {
  case drink {
    Water -> False
    Beer | Wine | GT -> True
  }
}

fn serve(person: Person, ordered: Drink) -> Drink {
  case is_alcoholic(ordered), person.age >= 16 {
    True, False -> Water
    _, _ -> ordered
  }
}

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

fn only_adults_are_served_alcohol(drink_order: DrinkOrder) -> Bool {
  let served = serve(drink_order.person, drink_order.beverage)
  !is_alcoholic(served) || drink_order.person.age >= 20
}

fn check_bar() {
  use drink_order <- for_all(drink_orders())
  only_adults_are_served_alcohol(drink_order)
}

pub fn main() {
  echo check_three_digits()
  echo check_bar()
}
