def compute_select(non_platform_items, platform_items):
    if not platform_items:
        return non_platform_items, {}

    item_values = platform_items.values()
    common_items = set(item_values[0])
    for values in item_values[1:]:
        common_items.intersection_update(values)
        if not common_items:
            break

    common_items.update(non_platform_items)

    branches = {}
    for platform, items in platform_items.items():
        items = set(items)
        items.difference_update(non_platform_items)
        items.difference_update(common_items)
        if items:
            branches[platform] = sorted(items)

    return common_items, branches
