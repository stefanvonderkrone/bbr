M23 published format review. Agent-authored test example.

P01 Plain prose keeps ordinary weight.

P02 **Bold outer with _italic inner_ and bold tail**.

P03 _Italic outer with **bold inner** and italic tail_.

P04 **Bold with `literal *code* :mask:`** and _italic with `literal **code** :mask:`_.

P05 [**Bold label**](https://example.invalid/bold), [_italic label_](https://example.invalid/italic), and [**bold with _italic inner_**](https://example.invalid/combined).

P06 ~~**Bold strike**~~, ~~_italic strike_~~, and [~~**bold _italic_ strike**~~](https://example.invalid/strike).

### P07 Heading with _italic_, [link](https://example.invalid/heading), and `code`

P08 **Emoji :mask:**, _emoji :heart:_, and [**emoji :woman_technologist::skin-tone-3:**](https://example.invalid/emoji).

P09 Unknown :not_a_real_emoji:, escaped \:mask:, and literal `:mask:` stay unchanged.

P10 Nested list with wrapped formatting:

3. Ordered parent with **bold**, _italic_, and `code`, plus enough plain words to wrap at a narrow Reply width.
    - Unordered child with [docs](https://example.invalid/list-child).
    - Second child with :mask: and ~~strike~~.
8. Second parent.

P11 Nested quote with a list and code:

> Quote with **bold**, _italic_, `code`, and [docs](https://example.invalid/quote).
>
> - Child item with enough words to wrap at a narrow Reply width without losing its continuation alignment.
>
> ```javascript
> const quoted = ":mask: **literal**";
> ```

P12 Table:

| Name | State | Detail |
| --- | --- | --- |
| **Ada** | _Ready_ :mask: | [docs](https://example.invalid/table) |
| `a|b` | ~~Waiting~~ | escaped \| pipe |
| Missing | Cell |
| Extra | Cell | Stays literal | Fourth cell |

P13 Image text with a destination and title:

![**diagram** :mask:](https://example.invalid/diagram.png "Optional diagram title")

P14 Reference link with a complete destination and title:

[**Docs with _italic_ and `code`**][guide]

[guide]: https://example.invalid/reference/complete/path?first=one&second=two#fragment "Optional reference title"

P15 JavaScript syntax colors with literal Markdown:

```javascript
const answer = 42;
const message = ":mask: **literal**";
function greet(name) {
    return `Hello ${name}`;
}
```

P16 Unknown language stays plain:

```m23-unknown-language
:mask: **literal** [docs](https://example.invalid/code)
```
