# Rust In Elixir - A Survival Guide

This is a live guide listing potential solutions to common problems you can face integrating Rust into Elixir projects, it will be updated as tools evolve and new problems or solutions are discovered. It's based on my own experience and opnion working on this space, it may not fit your needs but contributions and discussions are welcome.

Current version: 2026-05-08

Adopting Rust can solve a variety of problems:

- Performance
- Security
- Lack of libs

But it's not risk free, and rushing to writing code without understanding the implications might cause unexpected outcomes especially in production.

Following is a list of problems, concerns, and the potential solutions and at the end you find the mental model to architect Rust in Elixir in a sane and safe way and reference for further reading.

- [Understand the risks](#understand-the-risks)
- [Problems, Concerns, and Solutions](#problems-concerns-and-solutions)
  - [Dirty Scheduler](#dirty-scheduler)
  - [Encoding / Decoding](#encoding--decoding)
  - [Data Types](#data-types)
  - [Custom Data Types](#custom-data-types)
  - [Resources](#resources)
  - [Safe Rust](#safe-rust)
- [Mental Model](#mental-model)
- [References](#references)


## Understand the risks

If you don't want to read this whole doc, at least read this warning extracted from [erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html#description)

```
Use this functionality with extreme care.

A native function is executed as a direct extension of the native code of the VM. Execution is not made in a safe environment. The VM cannot provide the same services as provided when executing Erlang code, such as pre-emptive scheduling or memory protection. If the native function does not behave well, the whole VM will misbehave.

- A native function that crashes will crash the whole VM.
- An erroneously implemented native function can cause a VM internal state inconsistency, which can cause a crash of the VM, or miscellaneous misbehaviors of the VM at any point after the call to the native function.
- A native function doing lengthy work before returning degrades responsiveness of the VM, and can cause miscellaneous strange behaviors. Such strange behaviors include, but are not limited to, extreme memory usage, and bad load balancing between schedulers. Strange behaviors that can occur because of lengthy work can also vary between Erlang/OTP releases.
```

It may sound catastrophic but realiability is non-negotiable. Luckly we can be on the safe side by following some patterns:

## Problems, Concerns, and Solutions

### Dirty Scheduler

You write your first NIF and it works beautifully in tests:

```rust
#[rustler::nif()]
fn some_operation<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    ...
}
```

Then you deploy to production and latency goes to sky.

BEAM code is preemptively scheduled, processes run until they spend their reduction budget, then the scheduler can switch to another process. A normal NIF bypasses that mechanism. While the scheduler is executing native code, it cannot be preempted. If the NIF takes 1000ms, that scheduler is unavailable for 1000ms.

As the [doc says](https://www.erlang.org/doc/apps/erts/erl_nif.html#lengthy_work): "it is of vital importance that a native function returns relatively fast [...] A NIF that cannot be split and cannot execute in a millisecond or less is called a dirty NIF [...] It is important to classify the dirty job correct. An I/O bound job should be classified as such, and a CPU bound job should be classified as such".

Unless you're certain the NIF always returns within 1ms, you must flag the function to run in either the DirtyCPU scheduler or the DirtyIo scheduler using the [nif](https://docs.rs/rustler/latest/rustler/attr.nif.html) attribute macro:

```rust
#[nif(schedule = "DirtyCpu")]
```

Use `DirtyCpu` for work that burns CPU: parsing, hashing, compression, image processing, search, crypto.

Use `DirtyIo` for blocking work: filesystem, sockets, DNS, devices, or a C library doing blocking I/O.

Dirty schedulers are separate scheduler pools for work that should not run on the normal BEAM schedulers and you can fine-tune these pools with [`+SDcpu` and `+SDio`](https://www.erlang.org/doc/apps/erts/erl_cmd.html#+SDcpu) flags.

### Encoding / Decoding

AKA passing data over the boundaries between Elixir and Rust.

The code is well tested, everything works and is performant but then you're surprised with exceptions in production because some data shape is incorrect and the processes are crashing.

This is the kind of silent error you only observe at runtime if you're not cautious.

For example, this Rust function:

```rust
#[derive(rustler::NifMap)]
struct AssetPath {
    root: String,
    path: String,
}

#[nif(schedule = "DirtyCpu")]
fn rewrite_asset_url(asset_path: AssetPath) -> NifResult<String> {
    Ok(format!("{}{}", asset_path.root, asset_path.path))
}
```

Called by this Elixir code:

```elixir
asset_path = Jason.decode!(~s({"root":"https://cdn.example.com/","path":"app.css"}))
RustInElixir.Native.rewrite_asset_url(asset_path)
```

And surprise!


```text
** (ArgumentError) argument error
    (rust_in_elixir 0.1.0) RustInElixir.Native.rewrite_asset_url(%{"path" => "app.css", "root" => "https://cdn.example.com/"})
    (stdlib 7.3) erl_eval.erl:924: :erl_eval.do_apply/7
    (elixir 1.20.0-rc.2) lib/code.ex:634: Code.validated_eval_string/3
```

A [NifMap](https://docs.rs/rustler/latest/rustler/derive.NifMap.html) expects atom keys and you tried to pass string keys. The type looks right, the fields are present, but still gets a runtime crash.

Besides tests that exercise the actual data shape that you have in production, you can adopt [NimbleOptions](https://hexdocs.pm/nimble_options/NimbleOptions.html) to validate each piece of the data that must be passed between the boundaries to avoid such errors, or eventually adopt the upcoming Elixir type system.

### Data Types

Sometimes you spend half of the time just mapping data from one side to another.

Scalar data types are easy. Strings, integers, floats, booleans and lists usually map directly. The confusing parts are structs, maps and enums which are not so obvious at first.

#### Atoms to unit enums

Use [`NifUnitEnum`](https://docs.rs/rustler/latest/rustler/derive.NifUnitEnum.html) when each Rust enum variant maps to one Elixir atom.

```rust
#[derive(rustler::NifUnitEnum)]
enum Alignment {
    Left,
    Center,
    Right,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn align(alignment: Alignment) -> NifResult<String> {
    let class = match alignment {
        Alignment::Left => "text-left",
        Alignment::Center => "text-center",
        Alignment::Right => "text-right",
    };

    Ok(class.to_string())
}
```

Elixir:

```elixir
# Calls the Rust fn align/1 above.
# The atom :left decodes into Alignment::Left.
RustInElixir.Native.align(:left)
# "text-left"
```

Rustler converts Rust variant names from `CamelCase` to `snake_case` atoms. `FooBar` becomes `:foo_bar`.

#### Tagged tuples to enums

Use [`NifTaggedEnum`](https://docs.rs/rustler/latest/rustler/derive.NifTaggedEnum.html) when variants carry different data.

```rust
#[derive(rustler::NifTaggedEnum)]
enum UiEvent {
    Loading,
    Redirect(String),
    Resize { width: u32, height: u32 },
}

#[rustler::nif(schedule = "DirtyCpu")]
fn render_event(event: UiEvent) -> NifResult<String> {
    let rendered = match event {
        UiEvent::Loading => "loading".to_string(),
        UiEvent::Redirect(path) => format!("redirect to {path}"),
        UiEvent::Resize { width, height } => format!("resize to {width}x{height}"),
    };

    Ok(rendered)
}
```

Elixir:

```elixir
# Calls the Rust fn render_event/1 above.
# :loading decodes into UiEvent::Loading.
RustInElixir.Native.render_event(:loading)
# "loading"

# {:redirect, "/docs"} decodes into UiEvent::Redirect(String).
RustInElixir.Native.render_event({:redirect, "/docs"})
# "redirect to /docs"

# {:resize, %{...}} decodes into UiEvent::Resize { width, height }.
RustInElixir.Native.render_event({:resize, %{width: 800, height: 600}})
# "resize to 800x600"
```

The mapping is:

```elixir
:loading
{:redirect, value}
{:resize, %{width: value, height: value}}
```

#### Untagged unions

Use [`NifUntaggedEnum`](https://docs.rs/rustler/latest/rustler/derive.NifUntaggedEnum.html) when the type itself decides the variant.

```rust
#[derive(rustler::NifUntaggedEnum)]
enum Input {
    Id(u64),
    Name(String),
}

#[rustler::nif(schedule = "DirtyCpu")]
fn describe_input(input: Input) -> NifResult<String> {
    let description = match input {
        Input::Id(id) => format!("id={id}"),
        Input::Name(name) => format!("name={name}"),
    };

    Ok(description)
}
```

Elixir:

```elixir
# Calls the Rust fn describe_input/1 above.
# 123 decodes into Input::Id(123).
RustInElixir.Native.describe_input(123)
# "id=123"

# "hello" decodes into Input::Name("hello").
RustInElixir.Native.describe_input("hello")
# "name=hello"
```

#### Elixir Structs

Use [`NifStruct`](https://docs.rs/rustler/latest/rustler/derive.NifStruct.html) when Rust expects an Elixir struct.

```elixir
defmodule RustInElixir.Point do
  defstruct x: 0, y: 0
end
```

```rust
#[derive(rustler::NifStruct)]
#[module = "RustInElixir.Point"]
struct Point {
    x: i64,
    y: i64,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn move_point(point: Point, delta: Delta) -> NifResult<Point> {
    Ok(Point {
        x: point.x + delta.x,
        y: point.y + delta.y,
    })
}
```

Elixir:

```elixir
# Calls the Rust fn move_point/2 above.
# %RustInElixir.Point{} decodes into the Rust Point struct.
RustInElixir.Native.move_point(%RustInElixir.Point{x: 2, y: 3}, %{x: 10, y: 20})
# %RustInElixir.Point{x: 12, y: 23}
```

`NifStruct` expects the actual Elixir struct. Passing a plain map with the same fields, like `%{x: 2, y: 3}`, raises `ArgumentError` because it is missing `__struct__: RustInElixir.Point`.

#### Plain maps

Use [`NifMap`](https://docs.rs/rustler/latest/rustler/derive.NifMap.html) for plain Elixir maps with atom keys.

```rust
#[derive(rustler::NifMap)]
struct Delta {
    x: i64,
    y: i64,
}
```

Elixir:

```elixir
# When passed to move_point/2 above, this decodes into Delta { x: 10, y: 20 }.
%{x: 10, y: 20}
```

### Custom Data Types

Useful for custom validation or when the built-in types aren't enough for more complex cases.

For these cases you can implement [`Decoder`](https://docs.rs/rustler/latest/rustler/types/trait.Decoder.html) and [`Encoder`](https://docs.rs/rustler/latest/rustler/types/trait.Encoder.html) for the custom type you have.

If a Rust type implements `Decoder`, Rustler can receive it from Elixir. If it implements `Encoder`, Rustler can send it back to Elixir.

```rust
use rustler::{Decoder, Encoder, Env, Error, NifResult, Term};

struct NonEmptyString(String);

impl NonEmptyString {
    fn new(value: String) -> NifResult<Self> {
        let value = value.trim().to_string();

        if value.is_empty() {
            Err(Error::BadArg)
        } else {
            Ok(Self(value))
        }
    }
}

// Elixir -> Rust
impl<'a> Decoder<'a> for NonEmptyString {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        Self::new(term.decode::<String>()?)
    }
}

// Rust -> Elixir
impl Encoder for NonEmptyString {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        self.0.encode(env)
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn normalize_name(name: NonEmptyString) -> NifResult<NonEmptyString> {
    Ok(name)
}
```

Elixir:

```elixir
# Calls the Rust fn normalize_name/1 above.
# "  elixir  " decodes into NonEmptyString("elixir").
# The return value encodes back into an Elixir string.
RustInElixir.Native.normalize_name("  elixir  ")
# "elixir"

RustInElixir.Native.normalize_name("   ")
# ** (ArgumentError) argument error
```

Note how we added the capability to pass a String to a `NonEmptyString` and Rustler route the encoding/decoding properly.

But be careful because bad input that's not validated correctly becomes a NIF decode error at runtime.

### Resources

Resources are Rust-owned data behind an opaque Elixir reference.

The actual data stays in memory controlled by Rust. Elixir only gets a handle, and passes that handle back when it wants Rust to do something with the data.

Use resources when Rust needs to keep ownership of something large or stateful across multiple NIF calls. A CSV table is a good example: load it once, keep the parsed data in Rust, and let Elixir pass the handle around.

```text
Elixir process
  |
  |  table = Native.load_csv("big.csv")
  v
+-----------------------------+
| #Reference<...>              |  Elixir handle
+-----------------------------+
                  |
                  | references
                  v
+-----------------------------+
| Rust Table                  |  Rust-owned memory
| rows, columns, indexes      |
| native buffers, metadata    |
+-----------------------------+
```

The BEAM does not receive the whole table after every filter, join, select, or aggregation. Each call sends the handle back to Rust, and Rust operates on the native data.

Do not use a resource when a regular NIF can just return the answer. If you call Rust once with some input and get one result back, then a resource is probably not correct use.

On the Rust side you must implement [`Resource`](https://docs.rs/rustler/latest/rustler/trait.Resource.html), and values are wrapped in [`ResourceArc`](https://docs.rs/rustler/latest/rustler/struct.ResourceArc.html):

```rust
use rustler::{NifResult, Resource, ResourceArc};

struct Table {
    // Big native data lives here:
    // rows, columns, indexes, native buffers, metadata, etc.
    data: TableData,
}

#[rustler::resource_impl]
impl Resource for Table {}

#[rustler::nif(schedule = "DirtyCpu")]
fn load_csv(path: String) -> NifResult<ResourceArc<Table>> {
    // 1. Build the big value once in Rust memory.
    let data = ...; // parse CSV into native memory

    // 2. Return a handle to Elixir, not the table itself.
    Ok(ResourceArc::new(Table { data }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn filter(table: ResourceArc<Table>, column: String, value: String) -> NifResult<ResourceArc<Table>> {
    // 3. Decode the handle back into ResourceArc<Table>.
    // 4. Run the operation against Rust-owned memory.
    let data = ...; // filter the Rust-owned table

    // 5. Return another handle. The big table still does not cross into Elixir.
    Ok(ResourceArc::new(Table { data }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn summarize(table: ResourceArc<Table>) -> NifResult<Summary> {
    // 6. Do heavy work in Rust, but return a small Elixir-friendly value.
    ... // run a complex operation and return a small Elixir value
}
```

Elixir:

```elixir
# Loads and parses the CSV in Rust. Elixir receives only a handle.
table = Native.load_csv("huge.csv")
# #Reference<...>

# Sends the handle back to Rust. Rust filters the table in native memory.
filtered = Native.filter(table, "country", "BR")
# #Reference<...>

# Sends the handle back again. Rust computes a summary and returns a small map.
Native.summarize(filtered)
# %{rows: 1_200_000, columns: 42, ...}
```

Each NIF receives a handle, does the heavy work in Rust, and returns either another handle or a small Elixir value. 

[Explorer](https://github.com/elixir-explorer/explorer) makes extensive use of Resources and is a grea real-world example to learn more.

There are some implication on using resources that will be covered in a following update.

### Safe Rust

Rust is considered memory-safe language but it can be [unsafe](https://doc.rust-lang.org/book/ch20-01-unsafe-rust.html) which opens the door for operations that can segfault and crash the whole BEAM instance.

Do some research on the libs you're using and never use `unsafe` unless you absolutely need to.

## Mental Model

Now that we have applied the patterns above, we can think about where Rust fits in an Elixir project.

I like to think about it like another module in the system but written in Rust. Keep it boring.

```text
+-------------------------------------------------------------+
| Elixir application                                          |
|                                                             |
|  +------------------+      +-----------------------------+  |
|  | Accounts         |      | Markdown                    |  |
|  | Billing          |      | Search                      |  |
|  | Notifications    |      | Image                       |  |
|  +------------------+      +-----------------------------+  |
|                                      |                      |
|                                      v                      |
|                           +---------------------+           |
|                           | Markdown.Native     |           |
|                           | written in Rust     |           |
|                           +---------------------+           |
|                                                             |
|  Elixir still owns supervision, processes, messages,        |
|  validation, retries, timeouts and back-pressure.           |
+-------------------------------------------------------------+
```

The Elixir module is the public API. The Rust module is the implementation detail.

```elixir
defmodule MyApp.Markdown do
  def to_html(markdown, opts) do
    opts = validate_options!(opts)
    MyApp.Markdown.Native.to_html(markdown, opts)
  end
end
```

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn to_html(markdown: String, opts: Options) -> NifResult<String> {
    ...
}
```

Elixir is the coordinator and that's the reason I avoid async Ryst. The BEAM was made for concurrency and if Rust starts owning the workflow, spawning long-lived tasks, managing queues, retrying work, and keeping global application state, you no longer have "a Rust module in an Elixir app".

Error handling becomes a natural consequense of this mental modal and patterns.

## References

- <https://www.erlang.org/docs/26/man/erl_nif>
- <https://docs.rs/rustler/latest/rustler/trait.Resource.html>
- <https://blog.appsignal.com/2024/04/23/deep-diving-into-the-erlang-scheduler.html>
- <https://fly.io/phoenix-files/elixir-and-rust-is-a-good-mix/>
