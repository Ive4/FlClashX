import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/config/rules.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StandardContent extends ConsumerStatefulWidget {
  const StandardContent({super.key});

  @override
  ConsumerState createState() => _StandardContentState();
}

class _StandardContentState extends ConsumerState<StandardContent> {
  final _key = uniqueId;
  late int _profileId;

  Future<void> _handleAddOrUpdate([Rule? rule]) async {
    final res = await showFormSheet<Rule>(
      context: context,
      builder: (_) => RuleForm(rule: rule),
    );
    if (res == null || !mounted) {
      return;
    }
    ref.read(profileRulesProvider(_profileId).notifier).put(res);
  }

  void _handleQuickActions() {
    showSheet<void>(
      context: context,
      builder: (_) => RulePresetSheet(
        onAdd: ref.read(profileRulesProvider(_profileId).notifier).putAll,
      ),
    );
  }

  void _handleSelected(int ruleId) {
    ref.read(itemsProvider(_key).notifier).update((selectedRules) {
      final newSelectedRules = Set<int>.from(selectedRules)
        ..addOrRemove(ruleId);
      return newSelectedRules;
    });
  }

  void _handleSelectAll() {
    final ids =
        ref
            .read(profileRulesProvider(_profileId))
            .value
            ?.map((item) => item.id)
            .toSet() ??
        {};
    ref.read(itemsProvider(_key).notifier).update((selected) {
      return selected.containsAll(ids) ? {} : ids;
    });
  }

  Future<void> _handleDelete() async {
    final appLocalizations = context.appLocalizations;
    final res = await dialogs.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteMultipTip(appLocalizations.rule),
      ),
      destructive: true,
      confirmText: appLocalizations.delete,
    );
    if (res != true) {
      return;
    }
    final selectedRules = ref.read(itemsProvider(_key));
    ref
        .read(profileRulesProvider(_profileId).notifier)
        .delAll(selectedRules.cast<int>());
    ref.read(itemsProvider(_key).notifier).value = {};
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _profileId = ProfileIdProvider.of(context)!.profileId;
  }

  void _handleToEditGlobalAddedRules() {
    BaseNavigator.push(context, _EditGlobalAddedRules(_profileId));
  }

  Widget _buildRuleItem(List<Rule> rules, int index, Set<dynamic> selected) {
    final rule = rules[index];
    return ReorderableDelayedDragStartListener(
      key: ObjectKey(rule),
      index: index,
      child: ItemPositionProvider(
        position: ItemPosition.get(index, rules.length),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: RuleItem(
            hasMatch: true,
            isEditing: selected.isNotEmpty,
            isSelected: selected.contains(rule.id),
            rule: rule,
            onSelected: () {
              _handleSelected(rule.id);
            },
            onEdit: (rule) {
              _handleAddOrUpdate(rule);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    _profileId = ProfileIdProvider.of(context)!.profileId;
    final addedRules = ref.watch(profileRulesProvider(_profileId)).value ?? [];
    final globalRules = ref.watch(globalRulesProvider).value ?? const [];
    final disabled = ref.watch(profileDisabledRuleIdsProvider(_profileId));
    final disabledIds = disabled.value?.toSet() ?? const <int>{};
    final exitNames = {
      for (final rule in addedRules.followedBy(
        globalRules.where((rule) => !disabledIds.contains(rule.id)),
      ))
        if (rule.customExit)
          if (rule.ruleTarget?.trim() case final name? when name.isNotEmpty)
            name,
    }.toList()..sort();
    final selectedRules = ref.watch(itemsProvider(_key));
    return CommonPopScope(
      onPop: selectedRules.isEmpty
          ? null
          : (_) {
              ref.read(itemsProvider(_key).notifier).value = {};
              return false;
            },
      child: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListHeader(
                title: appLocalizations.addedRules,
                actions: [
                  if (selectedRules.isNotEmpty) ...[
                    IconButtonData(
                      glyph: AppGlyphs.delete,
                      tooltip: appLocalizations.delete,
                      onPressed: _handleDelete,
                    ),
                    IconButtonData(
                      glyph: AppGlyphs.selectAll,
                      tooltip: appLocalizations.selectAll,
                      onPressed: _handleSelectAll,
                    ),
                  ] else ...[
                    IconButtonData(
                      glyph: AppGlyphs.rulePresets,
                      tooltip: appLocalizations.quickActions,
                      onPressed: _handleQuickActions,
                    ),
                    IconButtonData(
                      glyph: AppGlyphs.addCircle,
                      tooltip: appLocalizations.add,
                      onPressed: _handleAddOrUpdate,
                    ),
                  ],
                ],
              ),
            ),
          ),
          SliverReorderableList(
            itemCount: addedRules.length,
            itemBuilder: (_, index) =>
                _buildRuleItem(addedRules, index, selectedRules),
            proxyDecorator: (child, index, animation) => commonProxyDecorator(
              _buildRuleItem(addedRules, index, selectedRules),
              index,
              animation,
            ),
            itemExtent: ruleItemHeight,
            onReorderItem: ref
                .read(profileRulesProvider(_profileId).notifier)
                .order,
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(child: _ExitTargetItem(_profileId)),
          if (exitNames.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ListHeader(title: appLocalizations.namedExits),
              ),
            ),
            SliverList.builder(
              itemCount: exitNames.length,
              itemBuilder: (_, index) =>
                  _ExitTargetItem(_profileId, exitName: exitNames[index]),
            ),
          ],
          SliverToBoxAdapter(
            child: MoreActionButton(
              label: appLocalizations.controlGlobalAddedRules,
              onPressed: _handleToEditGlobalAddedRules,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExitTargetItem extends ConsumerWidget {
  final int profileId;
  final String? exitName;

  const _ExitTargetItem(this.profileId, {this.exitName});

  String? _targetOf(Profile? profile) {
    final name = exitName;
    return name == null ? profile?.matchTarget : profile?.exitTargets[name];
  }

  Future<void> _handleSelect(BuildContext context, WidgetRef ref) async {
    final res = await showSheet<String>(
      context: context,
      builder: (context) => Consumer(
        builder: (_, ref, _) {
          final appLocalizations = context.appLocalizations;
          final clashConfig = ref.watch(clashConfigProvider(profileId)).value;
          final groups = clashConfig?.proxyGroups ?? const [];
          final proxies = clashConfig?.proxies ?? const [];
          final groupTypes = {
            for (final item in groups) item.name: item.type.name,
          };
          final proxyTypes = {for (final item in proxies) item.name: item.type};
          return SelectionSheet<String>(
            title: exitName ?? appLocalizations.matchTarget,
            sections: [
              const SelectionSection(items: ['']),
              SelectionSection(
                label: appLocalizations.basicStrategy,
                items: [
                  for (final name in RuleTarget.ruleTargetNames)
                    if (!groupTypes.containsKey(name)) name,
                ],
              ),
              SelectionSection(
                label: appLocalizations.ruleTarget,
                items: groupTypes.keys.toList(),
                subtitleBuilder: (_, name) => groupTypes[name] ?? '',
              ),
              SelectionSection(
                label: appLocalizations.proxies,
                items: proxyTypes.keys.toList(),
                subtitleBuilder: (_, name) => proxyTypes[name] ?? '',
              ),
            ],
            labelBuilder: (item) =>
                item.isEmpty ? appLocalizations.followProfile : item,
            selectedOf: (ref) => ref.watch(
              profileProvider(
                profileId,
              ).select((state) => _targetOf(state) ?? ''),
            ),
            onSelected: (item) => Navigator.of(context).pop(item),
          );
        },
      ),
    );
    if (res == null || !context.mounted) {
      return;
    }
    ref.read(profilesProvider.notifier).updateProfile(profileId, (state) {
      final name = exitName;
      if (name == null) {
        return state.copyWith(matchTarget: res.isEmpty ? null : res);
      }
      final exitTargets = {...state.exitTargets};
      if (res.isEmpty) {
        exitTargets.remove(name);
      } else {
        exitTargets[name] = res;
      }
      return state.copyWith(exitTargets: exitTargets);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final target = ref.watch(profileProvider(profileId).select(_targetOf));
    final clashConfig = ref.watch(clashConfigProvider(profileId)).value;
    final invalid =
        target != null &&
        clashConfig != null &&
        !RuleTarget.ruleTargets.contains(target) &&
        !clashConfig.proxyGroups.any((item) => item.name == target) &&
        !clashConfig.proxies.any((item) => item.name == target);
    return MoreActionButton(
      label: exitName ?? appLocalizations.matchTarget,
      trailing: Text(
        target ?? appLocalizations.followProfile,
        style: AppTextStyle.subheadline
            .of(context)
            .toJetBrainsMono
            .copyWith(
              color: invalid
                  ? context.colorScheme.error
                  : context.colorScheme.tertiary,
            ),
      ),
      onPressed: () {
        _handleSelect(context, ref);
      },
    );
  }
}

class _EditGlobalAddedRules extends ConsumerStatefulWidget {
  final int profileId;

  const _EditGlobalAddedRules(this.profileId);

  @override
  ConsumerState<_EditGlobalAddedRules> createState() =>
      _EditGlobalAddedRulesState();
}

class _EditGlobalAddedRulesState extends ConsumerState<_EditGlobalAddedRules> {
  var _query = SearchQuery('');
  final _searchTexts = Expando<String>();

  int get profileId => widget.profileId;

  void _handleChange(bool status, int ruleId) {
    if (status) {
      ref.read(profileDisabledRuleIdsProvider(profileId).notifier).put(ruleId);
    } else {
      ref.read(profileDisabledRuleIdsProvider(profileId).notifier).del(ruleId);
    }
  }

  void _handleSearch(String query) {
    setState(() {
      _query = SearchQuery(query);
    });
  }

  void _handleToAddedRules() {
    showInSheet<void>(context, builder: (_) => const AddedRulesView());
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final disabledRuleIdsState = ref.watch(
      profileDisabledRuleIdsProvider(profileId),
    );
    final disabledRuleIds = (disabledRuleIdsState.value ?? const <int>[])
        .toSet();
    final rulesState = ref.watch(globalRulesProvider);
    final rules = (rulesState.value ?? [])
        .whereMatches(_query, (rule) => rule.searchFields, texts: _searchTexts)
        .toList();
    return CommonScaffold(
      title: appLocalizations.editGlobalRules,
      searchState: AppBarSearchState(onSearch: _handleSearch),
      body: NullStatusSwitcher(
        isLoading: rulesState.isLoading || disabledRuleIdsState.isLoading,
        isEmpty: rules.isEmpty,
        isSearching: _query.isNotEmpty,
        nullStatus: NullStatus(
          label: appLocalizations.nullTip(appLocalizations.rule),
          illustration: NullStatusIllustration.rules,
          action: TonalButton(
            size: TonalButtonSize.bar,
            label: appLocalizations.goToConfigureAddedRules,
            onPressed: _handleToAddedRules,
          ),
        ),
        child: ScrollConfiguration(
          behavior: const ShowBarScrollBehavior(),
          child: Builder(
            builder: (context) => CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ).copyWith(top: context.contentTopPadding),
                  sliver: SliverFixedExtentList.builder(
                    itemExtent: ruleItemHeight,
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      final position = ItemPosition.get(index, rules.length);
                      return ItemPositionProvider(
                        position: position,
                        child: RuleStatusItem(
                          status: !disabledRuleIds.contains(rule.id),
                          rule: rule,
                          onChange: (status) {
                            _handleChange(!status, rule.id);
                          },
                        ),
                      );
                    },
                    itemCount: rules.length,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: MoreActionButton(
                    label: appLocalizations.goToConfigureAddedRules,
                    onPressed: _handleToAddedRules,
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(height: 12 + context.bottomInset),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
