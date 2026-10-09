# AeroGrid

AeroGrid is a configurable 4 x 4 glass-cockpit dashboard for EdgeTX color radios.
YAML layouts combine telemetry, model timers, flight tracking, switch states,
trim positions, and model images in responsive panels.

## Why AeroGrid?

EdgeTX is an excellent foundation: open source, remarkably configurable, and
flexible enough to support a wide range of radios and aircraft. AeroGrid builds
on those strengths rather than replacing them.

The dashboard experience has not always matched that flexibility. Many widgets
have a dated appearance, and mixing widgets from different authors often means
mixing different fonts, colors, spacing, and alarm styles. Individually useful
widgets do not necessarily add up to a coherent interface.

Earlier graphics APIs made polished, consistent interfaces harder to build.
With LVGL, EdgeTX now offers a more flexible foundation for a shared UI design
system. Projects such as Kyle Stacy's
[KSE Dashboards for Rotorflight helicopters](https://github.com/kylestacy2/KSE-Dashboards)
show what focused dashboards can offer. For fixed-wing pilots, however, options
for a modern, cohesive dashboard that can be freely rearranged remain limited.

AeroGrid's goal is to provide **flexible, configurable, modern-looking dashboards
and panels**, with a consistent visual language throughout. Choose the information
that matters to your model, arrange it in a YAML-defined grid, and keep the same
typography, spacing, colors, and state indicators across the dashboard.

## User Guide

Start with [installation and upgrades](user-guide/installation.md), then learn
how to [select and configure dashboards](user-guide/dashboards.md), bind sources,
and troubleshoot unavailable readings. Use the
[on-radio editor](user-guide/editor.md) to add, arrange, and configure panels
without editing YAML.

## Reference Guide

The [panel reference](reference-guide/index.md) describes each panel's
settings, presentations, and behavior when data is unavailable.

## Developer Guide

Learn how to [build and run the simulator](developer-guide/build.md),
[contribute changes](developer-guide/contributing.md), and work with the
[runtime architecture](developer-guide/architecture.md).
The [hardware validation record](hardware-validation.md) tracks radio observations
and remaining acceptance work.
