---
title: "DirectX 12 Mesh Shaders"
date: 2025-08-27T10:34:22+02:00
draft: true
---

While setting up a GPU driven pipeline for Ember, I decided to take a leap and learn about
Mesh Shaders, instead of sticking to the good old Vertex Shader.

In 2018, with the release of their Turing architecture GPUs, NVidia announced two technologies.
- **Hardware Raytracing** which everyone pays attention to.
- **Mesh Shaders** which almost flies under the radar.

This includes media about the intuitive usage of Mesh Shaders.
There are many talks and blog posts about Mesh Shaders, but I want to add my understanding of these
to the mix.
Note: I said _'these'_ - Mesh Shaders are often used in tandem with Amplification Shaders. (Task Shaders in Vulkan land)

They are rather simple in terms of understanding what each shader does, however, it can be a little difficult
to grasp how to make use of them.
I'm no expert, but hey, even I can explain some of my intuition and how I use them.

Since Ember is a D3D12 based engine, I will use D3D12 API terms and HLSL in this blog.
However, the concepts are exactly the same in vulkan - with minimal changes.

But first, let's get started with the background.

## Super-Basic Graphics Pipeline

```goat

 .--------------.     .---------------.     .----------.     .--------------.     .-------------.
| Input Assembly +--->| Vertex Shader +--->| Rasterizer +--->| Pixel Shader +--->| Output Merger |
 '--------------'     '---------------'     '----------'     '--------------'     '-------------'

```
Pretty simple - we get index buffers and vertex buffers.
GPU has fixed-function hardware to assemble a stream of primitives with
vertices.
Vertex Shader (VS) then _shades_ each of the vertices.
The rasterizer (fixed-function) converts the primitives into fragments (not exactly pixels just yet)
and then the Pixel Shader (PS) does whatever lighting calculations you want.
Finally, it is output.

This is all fine and dandy, but sometimes we need a flexible way to modify primitives
instead of singular vertices.
This can be for changing dynamic triangle subdivision, to draw different views to different render targets,
 or to even produce new primitives on the fly.
A Geometry Shader (GS) was spliced in between VS and Rasterizer as a 'solve-everything' solution.
A GS is very flexible - it takes primitives as inputs and can output an arbitrary number
of them, however we program it to. And does infact solve everything.
Except, at massive cost to performance on _most_ hardware. I only need to add 'most' due to the Intel
integrated cards actually providing decent performance with GS. (I don't know the performance on the ARC cards)
This is mostly due to the requirement that a GS runs per-primitive, but must output in sequence.
Sequential code on a parrallel processor doesn't have great performance, as expected.

The case of dynamic subdivisions, was solved by tesselation shaders which can only subdivide triangles, but work
far more efficiently than GS. Tesselation uses two shaders Domain shader and Hull shader.
They have a tesselator (fixed-function) that can generate primitives in a controlled and optimised way, for
better performance.

That, however, makes the pipeline (optionally) longer.

```goat


               .---------------.     .----------.     .-------------.    .-----------------.
            .->| Domain Shader +--->| Tesselator +--->| Hull Shader +--->| Geometry Shader +-.
           |   '---------------'     '----------'     '-------------'    '-----------------'  |
            '--------------------------.   .-------------------------------------------------'
 .--------------.     .---------------. | |    .----------.     .--------------.     .-------------.
| Input Assembly +--->| Vertex Shader +'   '->| Rasterizer +--->| Pixel Shader +--->| Output Merger |
 '--------------'     '---------------'        '----------'     '--------------'     '-------------'

```

What a scenic route!

## Enter GPU Driven Rendering

For modern rendering, it doesn't quite end there.
We've got all this geometry processing code.
However, the best geometry is the one that isn't drawn.

Culling is a way to ensure no unnecessary draws occur.
Traditionally, the CPU side code will cull the world down to individual meshes,
then dispatch draw calls for each mesh.
As the number of meshes increase in games, this cull and draw process started becoming
a bottleneck.

But at the same time, General Purpose GPU (GPGPU) usage became more accessible in graphics
API through Compute Shaders (CS).
So, a simple culling pipeline was created where CPU writes meshes to a buffer,
and the CS then culls each of the meshes in parallel, to produce a final 'to draw'
list.
They even removed the (slow) process of sending back the data to the CPU, by letting the
GPU directly write draw calls to a buffer.
The CPU then simply calls `ExecuteIndirect` (vulkan: `vkCmdDrawIndirect`) to tell the
GPU to execute all the commands stored on the buffer.

Compute was also used for other vertex manipulations such as skinning[^1], where the
processed vertices formed a new VB that is used by the VS as if it is a static mesh.
We have all these small tools that let us make limited changes to the vertices, and
this one program called compute shader that can do it all - so long as we get the
data from compute to graphics.

## Using Compute<sup>*</sup> everywhere.

<sup>*</sup> Okay we are not using the compute shaders - but this is compute.
In 2018, Mesh Shaders (MS) were introduced to effectively simplify compute use in
the geometry pipeline.
The concept is simple - why don't we replace everything before the rasterizer with
a (specialized) compute shader?

A mesh shader takes arbitrary data (yes, you're free to feed it whatever you want)
and produces a final set of triangles.

So, let's collapse the diagram shall we?

```goat

.-------------.     .----------.     .--------------.     .-------------.
| Mesh Shader +--->| Rasterizer +--->| Pixel Shader +--->| Output Merger |
'-------------'     '----------'     '--------------'     '-------------'

```

Let's look at the output of a mesh shader first, as it is structured.
A mesh shader provides three output keywords:
- `vertices` An array of vertex data.
- `indices` An array of primitive-indices into the vertex data array.
- `primitives` Per-primitive outputs which are not interpolated.

An MS threadgroup works together to produce these arrays.
However, there is a limit of 256 vertices and 256 primtives,
and 256 primtive indices (`uint3` for triangles, `uint2` for lines).
So, the overall mesh must be divided into smaller _meshlets_ that can each be processed
by a single MS threadgroup.
NVidia recommends 64 vertices and 126 primitives as the ideal size for
meshlets, but different architectures have different configurations to be used
depending on the ideal threadgroup size of the platform.

While some examples use a threadgroup of 128, and let each thread process <1 vertex
and ~1 index, this wastes a lot of resources, as the shaders diverge significantly
since half the threadgroup will never have vertices to process.
Threadgroup size of 64 yields a better mapping with ~1 vertex and \~2 primtives
per thread.

Now, for the input: Anything goes, but the general convention is to provide the meshlet
with levels of indirection.

```goat
                  .----------------------------+----------------------------.
                  |          Meshlet 0         |          Meshlet 1         |
                  +---------+-------+----------+---------+-------+----------+
                  | 1st Tri | # Tri | 1st Vert | 1st Tri | # Tri | 1st Vert |
                  +---------+-------+----------+---------+-------+----------+
Meshlet           |    0    |   2   |     0    |    2    |   1   |    4     |
                  '----+----+---+---+----------+---------+-------+----------'
                       |        |
                   .--'         |
                  |             v
                  v<--------------------->|  
                  .---+---+---+---+---+---+---+---+---.
Meshlet Triangles | 0 | 1 | 2 | 2 | 1 | 3 | 0 | 1 | 2 |
                  '-+-+-+-+-+-+---+---+---+---+---+---'
                    |   |    '--.
                    |    '-.     |
                    |       |    |
                    v       v    v
Meshlet Vertices  .-----+------+----+----+----.
                  |  15 |  16  | 17 | 18 | 19 |
                  '--+--+---+--+----+----+----'
                     |      |
                     v      v
VertexBuffer    --+------+------+--
                  | Data | Data |
                --+------+------+--

```

These levels of indirections are entirely in control of the developer, so you can use triangles directly
or create a triangle fan/strip.
And you're free to use any logic to compress the data, allowing you to set up smaller indices than a 
full 16 or 32 bit index buffer. For example, storing the top 16 bits in meshlet, then 8 bits in triangle,
and finally the meshlet vertices themselves can just be 8 bits.
Cost of decompression will often be cheaper than the bandwidth limits.

For the actual code, the header of a mesh shader usually looks as follows: 
```c++
[outputtopology("triangle")]
[numthreads(128, 1, 1)]
void main(
  uint3 group_id: SV_GroupID,
  uint3 local_id: SV_GroupThreadID,
  out vertices VertexOut vertices[64],
  out indices  uint3     triangles[124])
{
  
}
```

We set the output topology to a triangle.
This can either be a line or triangle in DX12, while Vulkan also supports points.

The number of threads in the threadgroup should be set according to the warp (NVidia)/wavefront (AMD).
Threadgroup of 32 matches with the warp size for NVidia and the wave32 profile on modern AMD cards,
and so is often used as the go-to value.

The `SV_GroupID` and `SV_GroupThreadID` are system-value symantics, which are pretty standard to compute
shaders. The declaration of these inputs could have been a separate input struct just like any compute shader.
So, the `group_id` tells us the index within the dispatch, so you can compute the meshlet that this refers to.
(I say can, since this is all very versatile and you can find other ways of doing things).
The `local_id` then maps to the thread in the group, and thus useful to compute the vertex or primitive
to process. This is not a 1:1 mapping, since the optimal number of threads is not (always) the same as the 
optimal number of vertices and primitives.

Which brings us to the important parameters. `out vertices` marks an array of vertices that is output from this
shader.

```goat

.----------------------.    .-------------.     .----------.     .--------------.     .-------------.
| Amplification Shader +--->| Mesh Shader +--->| Rasterizer +--->| Pixel Shader +--->| Output Merger |
'----------------------'    '-------------'     '----------'     '--------------'     '-------------'

```

# References

[^1]: Coenen, Simon, "Doom Eternal Study" 2020, https://simoncoenen.com/blog/programming/graphics/DoomEternalStudy 
