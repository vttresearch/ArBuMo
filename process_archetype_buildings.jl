#=
    process_archetype_buildings.jl

The main program for running the archetype building model via Spine Toolbox.
=#

using Pkg
Pkg.activate(@__DIR__)
using ArBuMo
using Test
m = ArBuMo

# Check that the necessary input arguments are provided
if length(ARGS) < 1
    @error """
    `process_archetype_buildings` requires at least the following input arguments:
    1. The `url` to a Spine Datastore containing the required input data and archetype building definitions.

    Furthermore, the following optional keyword arguments can be provided:
    2. `-spineopt <>`, the url to a Spine Datastore where the produced SpineOpt input data should be written.
    3. `-backbone <>`, the url to a Spine Datastore where the produced Backbone input data should be written.
    4. `-generic <>`, the url to a Spine Datastore where the produced Generic input data should be written.
    5. `-results <url>`, the url to a Spine Datastore where the baseline results are to be written. If not provided, results are written back into the input data url.
    6. `-save_layouts <false>`, controls whether the weather aggregation layouts are saved as images.
    7. `-alternative <"">`, the name of the alternative where the parameters are saved, empty by default.
    8. `-realization <realization>`, The name of the stochastic scenario containing true data over forecasts.
    """
else
    # Process command line arguments
    url_in = popfirst!(ARGS)
    kws = Dict(ARGS[i] => get(ARGS, i + 1, nothing) for i = 1:2:length(ARGS))
    spineopt_url = get(kws, "-spineopt", nothing)
    backbone_url = get(kws, "-backbone", nothing)
    generic_url = get(kws, "-generic", nothing)
    results_url = get(kws, "-results", url_in)
    save_layouts = lowercase(get(kws, "-save_layouts", "false")) == "true"
    alternative = get(kws, "-alternative", "")
    realization = Symbol(get(kws, "-realization", "realization"))

    # Open input database and run tests.
    @info "Opening input datastore at `$(url_in)`..."
    @time using_spinedb(url_in, m)

    # Run input data tests
    run_input_data_tests(m)

    # Process ScopeData and WeatherData, and create the ArchetypeBuildings
    scope_data_dictionary, archetype_dictionary =
        archetype_building_processing(
            m;
            save_layouts=save_layouts,
            realization=realization
        )

    # Heating/cooling demand calculations.
    archetype_results_dictionary = solve_archetype_building_hvac_demand(
        archetype_dictionary;
        mod=m,
        realization=realization
    )

    # Write the results back into the input datastore
    results__building_archetype,
    results__building_archetype__building_node,
    results__building_archetype__building_process,
    results__system_link_node = initialize_result_classes!(m)
    add_results!(
        results__building_archetype,
        results__building_archetype__building_node,
        results__building_archetype__building_process,
        results__system_link_node,
        archetype_results_dictionary;
        mod=m
    )
    @info "Importing `ArchetypeBuildingResults` into `$(results_url)`..."
    @time import_data(
        results_url,
        [
            results__building_archetype,
            results__building_archetype__building_node,
            results__building_archetype__building_process,
            results__system_link_node,
        ],
        "Importing `ArchetypeBuildingResults`.",
    )

    # Process input data if requested
    for (input_url, name, input) in [
        (spineopt_url, "SpineOpt", SpineOptInput),
        (backbone_url, "Backbone", BackboneInput),
        (generic_url, "Generic", GenericInput),
    ]
        if !isnothing(input_url)
            @info "Processing and writing $(name) input data into `$(input_url)`..."
            @time write_to_url(
                String(input_url),
                input(archetype_results_dictionary; mod=m);
                alternative=alternative
            )
        end
    end

    @info """
    All done!
    You can access the `ArchetypeBuilding` data in the `archetype_dictionary`,
    and the `ArchetypeBuildingResults` in the `archetype_results_dictionary`.
    `ScopeData` is also available in the `scope_data_dictionary`.
    """
end
