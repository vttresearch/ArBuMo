# ArBuWe.py

A [`PyPSA/atlite`](https://github.com/PyPSA/atlite)-based Python sub-module for processing weather data.

The aim of this sub-module is to automatically aggregate ERA5 weather data
for large geographical areas described using a shapefile,
a set of weights connected to the shapefile,
and an optional raster data file also used for weighting.
Since the Julia documenter doesn't know how to automatically handle Python
docstrings, interested readers unfortunately need to look into the code itself
for the technical details.
However, the following sections hope to at least give you a rough idea about what
the `ArBuWe.py` sub-module does.
Furthermore, the `testscript.ipynb` *Jupyter Notebook* included in this
repository provides and example how the weather data aggregation works.


## Input data requirements for the automatic weather data aggregation

The weather data aggregation is controlled by a few parameters in the 
[Input data reference](@ref):
- [shapefile\_path](@ref): Filepath pointing to a shapefile describing the geographical shape of the [building\_stock](@ref) in question.
- [weather\_start](@ref): The desired start of the weather period for the [building\_archetype](@ref).
- [weather\_end](@ref): The desired end of the weather period for the [building\_archetype](@ref).
- [raster\_weight\_path](@ref): An optional filepath to weighting raster data. *(See e.g. [Hotmaps residential heated gross floor area density data](https://gitlab.com/hotmaps/gfa_res_curr_density))*

While the [weather\_start](@ref) and [weather\_end](@ref) are more or less self-explanatory,
there are a few important things to know about the shapefile and optional
raster data:
- The shapefile and raster must use the *WGS 84 EPSG:4326* coordinate reference system, as it is required by `PyPSA/atlite` for correctly handling *ERA5* data.
- The shapefile must contain an attribute called `location`, with values corresponding to the [location\_id](@ref) *objects (not the [location\_name](@ref) parameters!)* for the included polygons. E.g. for my Finnish building stock data, I have a `FI.shp` containing a polygon for each municipality in Finland, with the `location` attribute containing the Finnish municipality code for each polygon.
- The absolute values of the optional raster data *don't matter*, as the data is normalized during the processing.


## High-level description of the weather data aggregation, the `aggregate_demand_and_weather` function

As explained by the [Process `WeatherData` structs](@ref) section,
the [`process_weather`](@ref) function is called to attempt to automatically
fetch and aggregate the desired weather data based on
[The `building_scope` definition](@ref).
Under the hood, the [`process_weather`](@ref) performs the following steps:
1. Call [`create_building_weather`](@ref) to do the preliminary heating/cooling demand and weather aggregation calculations.
2. Call [`calculate_effective_ground_temperature`](@ref) to calculate the aggregated average effective ground temperature based on the aggregated ambient air temperature.

The [`create_building_weather`](@ref) function is the main Julia function for
the weather data aggregation, and essentially just prepares input arguments for
the `aggregate_demand_and_weather` Python function, which could be called the
*main function* of the `ArBuWe.py` sub-module. The `aggregate_demand_and_weather`
essentially performs the following steps:

1. Load the shapefile from [shapefile\_path](@ref).
2. Prepare the `cutout` for `atlite` using [The `prepare_cutout` function](@ref).
3. Prepare the `layout` for `atlite` using [The `prepare_layout` function](@ref).
4. If `save_layouts == true`, plot diagnostics using [The `plot_layout` function](@ref).
5. Preprocess the necessary weather quantities using [The `preprocess_weather` function](@ref).
6. Calculates the initial heating and cooling demands using [The `process_initial_heating_demand` function](@ref).
    - When calculating the cooling demand, the ventilation heat recovery unit is assumed to be bypassed whenever it saves cooling energy. This is done by calculating the hourly steady-state cooling demand with the HRU both on and off, and then taking only the lower of the two for the final demand for each hour.
5. Aggregate and return the preliminary heating/cooling demands, as well as the necessary weather quantities.


### The `prepare_cutout` function

The `prepare_cutout` function takes as input the given `shapefile`,
`weather_start` and `weather_end`, and quite simply creates and prepares the `atlite` ERA5 cutout.
See the [`atlite` documentation](https://atlite.readthedocs.io/en/latest/introduction.html)
or their [*Creating a Cutout with ERA5* example](https://atlite.readthedocs.io/en/latest/examples/create_cutout.html) for more information.


### The `prepare_layout` function

The `prepare_layout` function takes the given `shapefile`, the optional
`raster_path`, as well as the `location_id_gfa_weights` produced by the
[`ArBuMo.process_building_stock_scope`](@ref) function,
and produces a `layout` raster for sampling the ERA5 weather data. Again, see the
[`atlite` documentation](https://atlite.readthedocs.io/en/latest/introduction.html)
for more information. The `layout` produced here is essentially identical to
the *capacity layouts* described in the documentation, except that ours is
normalized so that it results into a weighted average value,
instead of a cumulative value.

!!! note
    The `location_id_gfa_weights` have precedence over the optional
    `raster_path` weights. When both are used, the raster weights are normalized to match the corresponding `location_id_gfa_weights`, which are based on the `shapefile` vector GIS data. Thus, the `raster_path` is essentially only used to refine the distribution *inside* the `location_id` polygons of the `shapefile`.


### The `plot_layout` function

If the `save_layouts == true` *(false by default)* is set, the `plot_layout`
function is called to plot both the original `raster` weights,
as well as the layout from the [The `prepare_layout` function](@ref).
The diagnostic figures are saved under the `figs/` folder in the repository.
Here are example weather data aggregation `layouts` for Germany as plotted by
the `plot_layout` function, before and after matching the used polulation density
raster resolution to ERA5.

![DE_raster](WY-2019-DE_all_raster.png)
![DE_layout](WY-2019-DE_all_layout.png)


### The `preprocess_weather` function

After both the `cutout` and the `layout` have been processed,
the `preprocess_weather` function is called to calculate the weather
quantities required for both the rest of the preliminary heating/cooling demand
processing, as well as the later dynamic calculations in `ArBuMo.jl`. Essentially,
this means fetching/calculating the following:
1. Ambient temperature in [K].
2. Total **effective** irradiation in [W/m2] of **total** surface area, separately for horizontal and vertical surfaces.
    - The total irradiation includes diffuse, direct, and ground-reflected irradiation, as available from [`PyPSA/atlite`](https://github.com/PyPSA/atlite). Direct irradiation is subject to the assumed [external\_shading\_coefficient](@ref), while diffuse and ground-reflected irradiation are assumed to be unaffected by external shading.
    - The **total** surface area includes all of the horizontal and vertical surface area of the building envelope, not just the surface area facing the irradiation directly. For horizontal surfaces, this effective irradiation is the same as actual irradiation on a horizontal surface. However, for vertical surfaces, the effective irradiation is calculated as if the vertical surfaces face all directions in equal measure _(like a surface of a cylinder)_.


### The `process_initial_heating_demand` function

The `process_initial_heating_demand` function takes the preprocessed weather
quantities and the necessary archetype building parameters for calculating the
preliminary steady-state heating and cooling demands for the indoor air node.
Essentially, this means accounting for:
1. The desired temperature set point for the steady-state calculation.
2. Heat transfer between the indoor air node and ambient air temperature _(via ventilation, infiltration, thermal bridges, and through windows)_.
3. Convective internal heat gains on the interior air node.
4. Convective solar heat gains through the windows.

Since the function calculates the steady-state heating demand on the node,
the cooling demand can be extracted from the negative values of the resulting
demand time series. Thus, the same function can be used for calculating the
preliminary cooling demand as well.