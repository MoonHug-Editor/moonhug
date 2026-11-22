---
title: "UiShape"
description: "A UI graphic drawn with no sprite: a rectangle with a radius per corner, a border, a gradient, a drop shadow and an inner shadow"
weight: 15
tags: ["mhgui", "components", "shape", "rounded corners"]
---

A UI graphic that draws a shape with no sprite: a rectangle with a radius per corner, a border, a gradient and two shadows. It needs a RectTransform and a CanvasRenderer on its node ([UI canvas](/plugins/engine/docs/UICanvas.md)). GameObject, UI, Shape makes one, and Add Component lists it as UI, UiShape.

Panels, cards, buttons, pills, badges and input fields need no art this way, and the same UiShape holds up at any size.

## Example

```
Card       RectTransform size_delta 200, 130, CanvasRenderer, UiShape corner_radius 16, shadow color black 55%, offset 0 -10, blur 24
Button     RectTransform size_delta 200, 64, CanvasRenderer, UiShape corner_radius 12, border_width 2, gradient on, gradient_angle 270
Avatar     RectTransform size_delta 120, 120, CanvasRenderer, UiShape corner_radius 999, border_width 6
```

The card floats over the page on a soft shadow. The button is lighter at the top than at the bottom. The avatar frame is a circle: a square with a radius past half its side.

The sample scene `ui_demo.scene` of the `mhgui_sample` package shows eight of these side by side.

## Properties

| Field | Default | What it does |
|---|---|---|
| `color` | white | The fill, alpha included. Alpha 0 with a border draws an outline. |
| `material` | none | None draws with the plugin's shape material. Another material needs a shader with the same properties, below. |
| `raycast_target` | on | The pointer can hover and click this graphic. |
| `kind` | Rect | The outline. Rect is the only one. |
| `corner_radius` | 8 each | A radius per corner: top left, top right, bottom right, bottom left. |
| `border_width` | 0 | The border's width, from the edge inward. 0 draws none. |
| `border_color` | black | The border's colour. |
| `gradient` | off | The fill runs from `color` to `gradient_color` across the shape. |
| `gradient_color` | white | The fill's colour at the gradient's end. |
| `gradient_angle` | 0 | The gradient's direction in degrees: 0 runs left to right, 90 bottom to top. |
| `shadow` | no colour | A shadow behind the shape, below. |
| `inner_shadow` | no colour | A shadow inside the shape, on the fill. |

Sizes are in canvas units.

## Radius

- A radius is cut to half the shorter side. A large radius on every corner makes a pill, and on a square a circle.
- The border follows the corners: its inner edge has the radius less the border's width.

## Shadows

Both shadows have a `color`, an `offset`, a `blur` and a `spread`. A shadow draws when its colour has alpha.

- `offset` moves the shadow. Y is up, so a shadow under the shape has a negative y.
- `blur` is the width the shadow's edge fades over.
- `spread` grows the shadow before the blur. With no offset, a spread and a blur make a glow.
- The drop shadow reaches outside the node's rect. The rect, and what the pointer hits, stay the shape itself.
- The drop shadow fades with the fill's alpha: a shape with no fill casts none.
- The inner shadow darkens the fill near the edge, as an inset field has.

## How it draws

The UiShape is one quad at any size. The shader computes, for every pixel, its distance to the shape's edge and colours it from that.

- The edge is one pixel soft at any size, canvas scale and zoom, in a world-space canvas too.
- A field can change every frame at no cost: nothing is rebuilt.
- UiShapes with the same field values and the same size share a draw call when they are neighbours in draw order: a row of identical buttons is one draw. A text or an image drawn between two of them breaks the run, so give the labels a higher `z_index` than the shapes to keep the shapes together.
- A UiShape that differs from its neighbours is a draw call of its own.

## Another shader

The plugin's shader is `assets/shaders/ui_shape.glsl`. A material with another shader works when that shader declares the properties the UiShape sets, by name. Each is a vec4:

| Property | What the UiShape puts in it |
|---|---|
| `shape_size` | xy: the shape's size. zw: the quad's size, larger by the drop shadow's room |
| `shape_radii` | The four radii |
| `shape_params` | x: border width. y: gradient direction in radians. z: 1 with a gradient |
| `border_color`, `gradient_color` | The colours |
| `shadow_color`, `shadow_params` | The drop shadow: its colour, and xy offset, z blur, w spread |
| `inner_shadow_color`, `inner_shadow_params` | The inner shadow, the same way |

The quad's uvs run 0 to 1 over the whole quad, v up, and the fill is the vertex colour. A property the shader does not declare is dropped.

## Limits

- One outline, the rectangle. Circles and pills come from its radius.
- A gradient has two colours and runs in a straight line.
- The Scene window's selection outline and picking follow the quad, which a drop shadow makes larger than the rect.
