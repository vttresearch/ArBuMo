# ArBuMo.jl

A [SpineInterface.jl](https://github.com/Spine-project/SpineInterface.jl)-based
Julia module for aggregating building stock data into desired
archetype building lumped-capacitance thermal models.

The goal of this module is to provide an easy way to define and aggregate
building stock statistical data into arbitrary sets of synthetic average
archetype building lumped-capacitance thermal models, depicting the flexible
heating/cooling demand of a building stock.
These lumped-capacitance thermal models are created primarily for
seamless integration into large-scale energy system models like
[Backbone](https://cris.vtt.fi/en/publications/backbone) or
[SpineOpt](https://github.com/Spine-project/SpineOpt.jl),
in order to depict flexible heating/cooling demand of significant portions
of the building stock.

Essentially, this module takes input data and archetype building definitions
in the format detailed in the [Input data reference](@ref)
section as input, processes them according to the workflow detailed in the
[Overview of the workflow](@ref) section, and produces
lumped-capacitance thermal models of the desired synthetic average archetype
buildings depicting the heating/cooling demand and HVAC energy consumption
of a building stock, explained in the [Archetype building modelling](@ref) section.
The [ArBuWe.py](@ref) python sub-module provides
[PyPSA/atlite](https://github.com/PyPSA/atlite)-based automatic fetching
and processing of the necessary weather data based on the provided
archetype building definitions.
[Solving the baseline heating demand and HVAC equipment consumption](@ref)
is also calculated using very simple rule-based control keeping the node
temperatures within permitted limits.
The key outputs from this module are the readily made
[Backbone](https://cris.vtt.fi/en/publications/backbone) or
[SpineOpt](https://github.com/Spine-project/SpineOpt.jl) input datasets
that can be plugged into their respective energy system models for
depicting the flexible heating/cooling demand of the depicted building stock.

This documentation is organized as follows:
The [Defining archetype buildings](@ref) section explains how the archetype
buildings are defined, meaning the key components in the
[Input data reference](@ref), and how to use them.
The [Overview of the workflow](@ref) section goes through the
`run_ArBuMo.jl` main program file, explaining what is
actually being done when aggregating the building stock data into the
desired synthetic average archetype buildings.
The [Archetype building modelling](@ref) section explains the lumped-capacitance
thermal modelling approach used by this module in more detail,
while the [ArBuWe.py](@ref) section briefly explains
the logic and workings of the python sub-module handling the automatic
weather data processing.
The [Input data processing for large-scale energy system modelling frameworks](@ref)
section provides an overview of how the data is further processed to be compatible
with [Backbone](https://cris.vtt.fi/en/publications/backbone)
and [SpineOpt](https://github.com/Spine-project/SpineOpt.jl).
Finally, the [Input data reference](@ref) and the [Library](@ref)
sections provide comprehensive documentation of the definition/input
data format and the modelling code respectively.


## Key limitations

Due to the used simplified modelling approach, there are several key limitations for the model that users should be aware of:

1. **ArBuMo.jl primarily aims to depict the *flexibility* in building stock heating/cooling demand, and *NOT* the demand itself.** While the model produces baseline heating and cooling demand timeseries, it is important to understand that these timeseries are oversimplified compared to the actual demand. Due to the limited number of archetype buildings and the used single-zone approach, there can be relatively long periods where, *on average*, the model requires no heating and cooling at all. In reality, it is all but guaranteed that there will always be some buildings *(or zones therein)* requiring at least some cooling and/or heating at any given time.

2. **Several real-life phenomena affecting the heating/cooling demand are neglected for simplicity:**
    - Potential opening of doors/windows for additional ventilation or cooling by the inhabitants, likely resulting in overestimated cooling demand flexibility.
    - Potential use of active solar shading elements in buildings, e.g. blinds, for reducing solar heat gains in summer to reduce cooling loads. Likely results in overestimated cooling demand.
    - Potential change in inhabitant behaviour to increase/reduce internal heat gains depending on indoor air temperature.


## Related works

There's the original [ArchetypeBuildingModel.jl](https://github.com/vttresearch/ArchetypeBuildingModel)
that I tried to improve upon with this module, but ultimately I'm
uncertain if it will end up being worth the effort.


## Future work?

The new formulation, in principle, enables investment decisions related to the
building stock heating fuel mix as well as heating/cooling flexibility
separately. However, turns out the simplest formulation requires
functionality not currently present in [Backbone](https://cris.vtt.fi/en/publications/backbone)
or [SpineOpt](https://github.com/Spine-project/SpineOpt.jl).
Thus, the input data interfaces need to be reworked after the required
energy system model functionality is in place.

Furthermore, I'm still not completely happy with the heating and cooling demand timeseries.
Even though the "preliminary" heating and cooling demand for the indoor air node
is calculated in [ArBuWe.py](@ref) using [PyPSA/atlite](https://github.com/PyPSA/atlite)
on `xarray` level to better account for differences in geospatial weather,
the thermal mass correction done at archetype building level with "average weather"
still seems to result in very specific heating demand profiles.
Moving the thermal mass dynamics to Python `xarray` level could potentially help,
but I have no idea whether the required calculations could be performed
in a computationally practical manner.


## Contents

```@contents
```