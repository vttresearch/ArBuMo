# Overview of the workflow

The following sections aim to go over the main program file `run_ArBuMo.jl`
and explain the high-level workflow of `ArBuMo.jl`.
Links are provided to the detailed explanations of the different data structures
and functions in the [Library](@ref) section for readers interested in the
technical details.


## Command line arguments

The `run_ArBuMo.jl` main program file has been primarily
designed to be run via [Spine Toolbox](https://github.com/Spine-project/Spine-Toolbox),
but be run directly from the command line as well if necessary.
Regardless, the main program is controlled using the following command line arguments:
1. The `url` to a *Spine Datastore* containing the required input data and archetype building definitions.
Furthermore, the following optional keyword arguments can be provided:
- `-spineopt <>`, the url to a *Spine Datastore* where the produced *SpineOpt* input data should be written, if any.
- `-backbone <>`, the url to a *Spine Datastore* where the produced *Backbone* input data should be written, if any.
- `-generic <>`, the url to a Spine Datastore where the produced Generic input data should be written. This is essentially a dump of the raw *ArBuMo.jl* data structures, primarily useful for debugging purposes.
- `results <url>`, url to a *Spine Datastore* where the produced baseline HVAC demand results should be written. By default, the results are written back into the input datastore at `url`.
- `-save_layouts <false>`, controls whether auto-generated weather aggregation layouts are saved as images. Set to `false` by default, as this keyword exists primarily for debugging purposes, allowing visual inspection of the weather data weighting rasters.
- `alternative <"">`, the name of the *Spine Datastore* alternative where the `-spineopt`, `-backbone`, or `-generic` input data are saved. An empty string by default, resulting in *Spine Toolbox* automatically generating an alternative name when importing the parameter values.
- `realization <realization>`, The name of the stochastic scenario containing true data over forecasts. Only relevant if stochastic weather and/or load data is used.


## Input database tests

Next, the main program opens the input *Datastore*, and performs a series
of tests on the input data and archetype building definitions to check that
they make sense. If not, the main program will halt and display the test
results and error messages for the user, in order to help them deduce what is
wrong with the input data or definitions.

The input *Datastore* tests are handled by the [`run_object_class_tests`](@ref),
[`run_parameter_tests`](@ref), and [`run_structure_type_tests`](@ref) functions.


## Process `ScopeData` structs

As explained by [The `building_scope` definition](@ref) section,
the [building\_scope](@ref) defines the geographical and statistical scope
for a [building\_archetype](@ref). Before we can begin creating
lumped-capacitance thermal models for the archetype buildings, the main program
first needs to know the aggregated average basic properties of the archetype.
Thus, the next step is to process and create the [`ScopeData`](@ref) structs
for all the [building\_scope](@ref)s attached to a [building\_archetype](@ref)
via a [building\_archetype\_\_building\_scope](@ref) relationship
*(scopes not attached to any archetype are not processed)*.

The final [`ScopeData`](@ref) structs are stored into a
`scope_data_dictionary`, which can be examined through the Julia REPL
after the main program has finished.
Alternatively, the `-generic` keyword can be used to export the raw data
structures to a Spine Datastore for inspection.


## Process `ArchetypeBuilding` structs

Next, the main program processes all the data into lumped-capacitance thermal
models depicting the desired synthetic average archetype buildings.
This is handled by the [`ArchetypeBuilding`](@ref)
struct constructor, and takes as input [The `building_archetype` definition](@ref),
as well as the appropriate [`ScopeData`](@ref) processed during the previous step.

The [`ArchetypeBuilding`](@ref) contains all the information about the final
lumped-capacitance thermal model of the synthetic average archetype building,
as well as the definitions used in its construction. The final
[`ArchetypeBuilding`](@ref) structs are stored into an `archetype_dictionary`,
which can be examined through the Julia REPL after the main program has finished.
Alternatively, the `-generic` keyword can be used to export the raw data
structures to a Spine Datastore for inspection.


### Process `WeatherData` structs

Automatic weather data processing using the [`ArBuWe.py`](@ref) sub-module
takes place during [`ArchetypeBuilding`](@ref) processing.
Here, the [`ArBuMo.process_weather`](@ref) function doing most of the heavy
lifting based on [The `building_archetype` definition](@ref) and the
processed [`ScopeData`](@ref). The final [`WeatherData`](@ref) structs are stored
into a `weather_data_dictionary`, which can be examined through the Julia REPL
after the main program has finished.
Alternatively, the `-generic` keyword can be used to export the raw data
structures to a Spine Datastore for inspection.

See the [ArBuWe.py](@ref) section for more details on the weather data processing.


## Solve the HVAC demand

After processing the [`ArchetypeBuilding`](@ref)s, the main program will
calculate a baseline/reference heating/cooling demand using the
lumped-capacitance thermal models of the synthetic average archetype buildings.
This is handled by the [`ArchetypeBuildingResults`](@ref) struct and its
constructor.

The final [`ArchetypeBuildingResults`](@ref) are written back into the
input *Datastore*, as well as stored into an `archetype_results_dictionary`,
which can be examined through the Julia REPL after the main program has finished.
Alternatively, the `-generic` keyword can be used to export the raw data
structures to a Spine Datastore for inspection.


## Export SpineOpt input data

!!! note 
    `SpineOpt` input data interface is currently not working, as the full investment formulation requires new functionality in `SpineOpt` to be implemented first.

If the `-spineopt <url>` argument is given, the main program will attempt to
convert the [`ArchetypeBuilding`](@ref)s in the `archetype_dictionary`
into *SpineOpt* energy system model input data, and export that input data into
the *Spine Datastore* at the given `url`.

The input data creation is handled by the [`SpineOptInput`](@ref) struct and
its constructor.


## Export Backbone input data

!!! note 
    `Backbone` input data interface is currently not working, as the full investment formulation requires new functionality in `Backbone` to be implemented first.

If the `-backbone <url>` argument is given, the main program will attempt to
convert the [`ArchetypeBuilding`](@ref)s in the `archetype_dictionary`
into *Backbone* energy system model input data, and export that input data into
the *Spine Datastore* at the given `url`.

The input data creation is handled by the [`BackboneInput`](@ref) struct and
its constructor.


## Export Generic input data

If the `-generic <url>` argument is given, the main program will attempt to
save the processed [`ArchetypeBuildingResults`](@ref) in the
`archetype_results_dictionary` in their entirety into the
*Spine Datastore* at the given `url`.
Essentially, this means saving all of the following:
- Processed [`WeatherData`](@ref) structs.
- [building\_scope](@ref) definitions with their associated [`ScopeData`](@ref).
- [building\_archetype](@ref) definitions, with their associated [`EnvelopeData`](@ref), [`BuildingNodeData`](@ref),  [`BuildingProcessData`](@ref), [`LoadsData`] and, [`AbstractNode`](@ref).

The name "Generic" is perhaps a bit misleading, and should probably be renamed
to e.g. "Raw" at some future point in time?