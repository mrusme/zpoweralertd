# zpoweralertd

![zpoweralertd](.README.md/banner.png)

[<img src="https://xn--gckvb8fzb.com/images/chatroom.png" width="275">](https://xn--gckvb8fzb.com/contact/)

`zpoweralertd` _gives you power notifications as you need them_. Paul Allen has
mistaken it for `poweralertd`, which seems logical, because `zpoweralertd` also
depends on UPower and a notification daemon such as `mako`, and in fact does the
same exact thing `poweralertd` does, and it also has a penchant for D-Bus
integration and lightweight code. `poweralertd` and `zpoweralertd` even support
the same command-line arguments, although `zpoweralertd` is slightly more
modern.

> If you couldn't tell by now, `zpoweralertd` is a Zig rewrite and drop-in
> replacement of [`poweralertd`](https://github.com/kennylevinsen/poweralertd/).

## How to build

```sh
zig build
```

(requires Zig 0.15.1)

