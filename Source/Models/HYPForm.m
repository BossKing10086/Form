#import "HYPForm.h"

#import "HYPFormSection.h"
#import "HYPFormField.h"
#import "HYPFieldValue.h"
#import "HYPFormTarget.h"

#import "NSDictionary+HYPSafeValue.h"
#import "NSString+HYPFormula.h"
#import "HYPClassFactory.h"
#import "HYPValidator.h"

@interface HYPForm ()

@property (nonatomic, strong) NSMutableDictionary *requiredFieldIDs;

@end

@implementation HYPForm

+ (instancetype)sharedInstance
{
    static HYPForm *_sharedClient;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        _sharedClient = [HYPForm new];
    });

    return _sharedClient;
}

- (NSMutableDictionary *)requiredFieldIDs
{
    if (_requiredFieldIDs) return _requiredFieldIDs;

    NSMutableDictionary *fields = [NSMutableDictionary dictionary];

    NSArray *JSON = [self JSONObjectWithContentsOfFile:@"forms.json"];

    for (NSDictionary *formDict in JSON) {
        NSArray *dataSourceSections = [formDict hyp_safeValueForKey:@"sections"];
        [dataSourceSections enumerateObjectsUsingBlock:^(NSDictionary *sectionDict, NSUInteger sectionIndex, BOOL *stop) {
            NSArray *dataSourceFields = [sectionDict hyp_safeValueForKey:@"fields"];
            [dataSourceFields enumerateObjectsUsingBlock:^(NSDictionary *fieldDict, NSUInteger fieldIndex, BOOL *stop) {
                NSDictionary *validations = [fieldDict hyp_safeValueForKey:@"validations"];
                BOOL required = [[validations hyp_safeValueForKey:@"required"] boolValue];
                if (required) {
                    [fields setObject:fieldDict forKey:[fieldDict hyp_safeValueForKey:@"id"]];
                }
            }];
        }];
    }

    _requiredFieldIDs = fields;

    return _requiredFieldIDs;
}

- (NSMutableArray *)formsUsingInitialValuesFromDictionary:(NSMutableDictionary *)dictionary
                                                 disabled:(BOOL)disabled
                                        disabledFieldsIDs:(NSArray *)disabledFieldsIDs
                                         additionalValues:(void (^)(NSMutableDictionary *deletedFields,
                                                                    NSMutableDictionary *deletedSections))additionalValues
{
    NSArray *JSON = [self JSONObjectWithContentsOfFile:@"forms.json"];

    NSMutableArray *forms = [NSMutableArray array];

    NSMutableArray *targetsToRun = [NSMutableArray array];

    NSMutableArray *fieldsWithFormula = [NSMutableArray array];

    [JSON enumerateObjectsUsingBlock:^(NSDictionary *formDict, NSUInteger formIndex, BOOL *stop) {

        HYPForm *form = [HYPForm new];
        form.formID = [formDict hyp_safeValueForKey:@"id"];
        form.title = [formDict hyp_safeValueForKey:@"title"];
        form.position = @(formIndex);

        NSMutableArray *sections = [NSMutableArray array];
        NSArray *dataSourceSections = [formDict hyp_safeValueForKey:@"sections"];
        NSDictionary *lastObject = [dataSourceSections lastObject];

        [dataSourceSections enumerateObjectsUsingBlock:^(NSDictionary *sectionDict, NSUInteger sectionIndex, BOOL *stop) {

            HYPFormSection *section = [HYPFormSection new];
            section.sectionID = [sectionDict hyp_safeValueForKey:@"id"];
            section.position = @(sectionIndex);

            BOOL isLastSection = (lastObject == sectionDict);

            if (isLastSection) section.isLast = YES;

            NSArray *dataSourceFields = [sectionDict hyp_safeValueForKey:@"fields"];
            NSMutableArray *fields = [NSMutableArray array];

            [dataSourceFields enumerateObjectsUsingBlock:^(NSDictionary *fieldDict, NSUInteger fieldIndex, BOOL *stop) {

                NSString *remoteID = [fieldDict hyp_safeValueForKey:@"id"];

                HYPFormField *field = [HYPFormField new];
                field.fieldID   = remoteID;
                field.title = [fieldDict hyp_safeValueForKey:@"title"];
                field.typeString  = [fieldDict hyp_safeValueForKey:@"type"];
                field.type = [field typeFromTypeString:[fieldDict hyp_safeValueForKey:@"type"]];
                NSNumber *width = [fieldDict hyp_safeValueForKey:@"size.width"];
                NSNumber *height = [fieldDict hyp_safeValueForKey:@"size.height"];
                if (!height || !width) abort();

                field.size = CGSizeMake([width floatValue], [height floatValue]);
                field.position = @(fieldIndex);
                field.validations = [fieldDict hyp_safeValueForKey:@"validations"];
                field.disabled = [[fieldDict hyp_safeValueForKey:@"disabled"] boolValue];
                field.formula = [fieldDict hyp_safeValueForKey:@"formula"];
                field.targets = [self targetsUsingArray:[fieldDict hyp_safeValueForKey:@"targets"]];

                BOOL shouldDisable = (disabled || [disabledFieldsIDs containsObject:field.fieldID]);

                if (shouldDisable) field.disabled = YES;

                NSMutableArray *values = [NSMutableArray array];
                NSArray *dataSourceValues = [fieldDict hyp_safeValueForKey:@"values"];

                if (dataSourceValues) {
                    for (NSDictionary *valueDict in dataSourceValues) {
                        HYPFieldValue *fieldValue = [HYPFieldValue new];
                        fieldValue.valueID = [valueDict hyp_safeValueForKey:@"id"];
                        fieldValue.title = [valueDict hyp_safeValueForKey:@"title"];
                        fieldValue.value = [valueDict hyp_safeValueForKey:@"value"];

                        BOOL needsToRun = NO;

                        if ([dictionary hyp_safeValueForKey:remoteID]) {
                            if ([fieldValue identifierIsEqualTo:[dictionary hyp_safeValueForKey:remoteID]]) {
                                needsToRun = YES;
                            }
                        }

                        NSArray *targets = [self targetsUsingArray:[valueDict hyp_safeValueForKey:@"targets"]];
                        for (HYPFormTarget *target in targets) {
                            target.value = fieldValue;

                            if (needsToRun && target.actionType == HYPFormTargetActionHide) [targetsToRun addObject:target];
                        }

                        fieldValue.targets = targets;
                        fieldValue.field = field;
                        [values addObject:fieldValue];
                    }
                }

                if ([dictionary hyp_safeValueForKey:remoteID]) {
                    if (field.type == HYPFormFieldTypeSelect) {
                        for (HYPFieldValue *value in values) {

                            BOOL isInitialValue = ([value identifierIsEqualTo:[dictionary hyp_safeValueForKey:remoteID]]);

                            if (isInitialValue) field.fieldValue = value;
                        }
                    } else {
                        field.fieldValue = [dictionary hyp_safeValueForKey:remoteID];
                    }
                }

                field.values = values;
                field.section = section;
                [fields addObject:field];

                if (field.formula) [fieldsWithFormula addObject:field];
            }];

            if (!isLastSection) {
                HYPFormField *field = [HYPFormField new];
                field.sectionSeparator = YES;
                field.position = @(fields.count);
                field.section = section;
                [fields addObject:field];
            }

            section.fields = fields;
            section.form = form;
            [sections addObject:section];
        }];

        form.sections = sections;
        [forms addObject:form];
    }];

    [self processFieldsWithFormula:fieldsWithFormula inForms:forms usingValues:dictionary];

    [self processHiddenFieldsInTargets:targetsToRun
                               inForms:forms
                            completion:^(NSMutableDictionary *fields, NSMutableDictionary *sections) {
                                [self removeHiddenFieldsInTargets:targetsToRun inForms:forms];

                                if (additionalValues) additionalValues(fields, sections);
                            }];

    return forms;
}

- (NSArray *)targetsUsingArray:(NSArray *)array
{
    NSMutableArray *targets = [NSMutableArray array];

    for (NSDictionary *targetDict in array) {
        HYPFormTarget *target = [HYPFormTarget new];
        target.targetID = [targetDict hyp_safeValueForKey:@"id"];
        target.typeString = [targetDict hyp_safeValueForKey:@"type"];
        target.actionTypeString = [targetDict hyp_safeValueForKey:@"action"];
        [targets addObject:target];
    }

    return targets;
}

- (id)JSONObjectWithContentsOfFile:(NSString*)fileName
{
    NSString *filePath = [[NSBundle mainBundle] pathForResource:[fileName stringByDeletingPathExtension]
                                                         ofType:[fileName pathExtension]];

    NSData *data = [NSData dataWithContentsOfFile:filePath];

    NSError *error = nil;

    id result = [NSJSONSerialization JSONObjectWithData:data
                                                options:NSJSONReadingMutableContainers
                                                  error:&error];
    if (error != nil) return nil;

    return result;
}

- (NSArray *)fields
{
    NSMutableArray *array = [NSMutableArray array];

    for (HYPFormSection *section in self.sections) {
        [array addObjectsFromArray:section.fields];
    }

    return array;
}

- (NSInteger)numberOfFields
{
    NSInteger count = 0;

    for (HYPFormSection *section in self.sections) {
        count += section.fields.count;
    }

    return count;
}

- (NSInteger)numberOfFields:(NSMutableDictionary *)deletedSections
{
    NSInteger count = 0;

    for (HYPFormSection *section in self.sections) {
        if (![deletedSections objectForKey:section.sectionID]) {
            count += section.fields.count;
        }
    }

    return count;
}

- (void)printFieldValues
{
    for (HYPFormSection *section in self.sections) {
        for (HYPFormField *field in section.fields) {
            NSLog(@"field key: %@ --- value: %@ (%@ : %@)", field.fieldID, field.fieldValue,
                  field.section.position, field.position);
        }
    }
}

#pragma mark - Private Methods

- (void)processFieldsWithFormula:(NSArray *)fieldsWithFormula inForms:(NSArray *)forms
                     usingValues:(NSMutableDictionary *)currentValues
{
    for (HYPFormField *field in fieldsWithFormula) {
        NSMutableDictionary *values = [field valuesForFormulaInForms:forms];
        id result = [field.formula hyp_runFormulaWithDictionary:values];
        field.fieldValue = result;
        if (result) [currentValues setObject:result forKey:field.fieldID];
    }
}

- (void)processHiddenFieldsInTargets:(NSArray *)targets
                             inForms:(NSArray *)forms
                          completion:(void (^)(NSMutableDictionary *fields,
                                               NSMutableDictionary *sections))completion
{
    NSMutableDictionary *hiddenFields = [NSMutableDictionary dictionary];
    NSMutableDictionary *hiddenSections = [NSMutableDictionary dictionary];

    for (HYPFormTarget *target in targets) {

        if (target.type == HYPFormTargetTypeField) {

            HYPFormField *field = [HYPFormField fieldWithID:target.targetID inForms:forms withIndexPath:YES];
            [hiddenFields addEntriesFromDictionary:@{target.targetID : field}];

        } else if (target.type == HYPFormTargetTypeSection) {

            HYPFormSection *section = [HYPFormSection sectionWithID:target.targetID inForms:forms];
            [hiddenSections addEntriesFromDictionary:@{target.targetID : section}];
        }
    }

    if (completion) {
        completion(hiddenFields, hiddenSections);
    }
}

- (void)removeHiddenFieldsInTargets:(NSArray *)targets inForms:(NSArray *)forms
{
    for (HYPFormTarget *target in targets) {

        if (target.type == HYPFormTargetTypeField) {

            HYPFormField *field = [HYPFormField fieldWithID:target.targetID inForms:forms withIndexPath:NO];
            HYPFormSection *section = [HYPFormSection sectionWithID:field.section.sectionID inForms:forms];
            [section removeField:field inForms:forms];

        } else if (target.type == HYPFormTargetTypeSection) {

            HYPFormSection *section = [HYPFormSection sectionWithID:target.targetID inForms:forms];
            HYPForm *form = forms[[section.form.position integerValue]];
            NSInteger index = [section indexInForms:forms];
            [form.sections removeObjectAtIndex:index];
        }
    }
}

@end
