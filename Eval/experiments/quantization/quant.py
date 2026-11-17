import sys, coremltools as ct, coremltools.optimize.coreml as cto
variant, src, dst = sys.argv[1:4]
m = ct.models.MLModel(src, compute_units=ct.ComputeUnit.CPU_ONLY)
m = cto.decompress_weights(m)
if variant != 'int8c':
    sp = m.get_spec(); sp.specificationVersion = 9
    m = ct.models.MLModel(sp, weights_dir=m.weights_dir, compute_units=ct.ComputeUnit.CPU_ONLY)
if variant == "int8c":
    cfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
    m = cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cfg))
elif variant == "int4b32":
    cfg = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32)
    m = cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cfg))
elif variant == "pal4g16":
    cfg = cto.OpPalettizerConfig(mode="kmeans", nbits=4, granularity="per_grouped_channel", group_size=16)
    m = cto.palettize_weights(m, cto.OptimizationConfig(global_config=cfg))
m.save(dst)
