import type { BackendService } from "../backend/backendService";
import {
  OperationRunRpcClient,
  type AddOperationRequest,
  type BranchCreateOperationRequest,
  type ChangelistClearOperationRequest,
  type ChangelistSetOperationRequest,
  type CleanupOperationRequest,
  type CommitOperationRequest,
  type LockOperationRequest,
  type MergeRangeOperationRequest,
  type MoveOperationRequest,
  type OperationClient,
  type OperationRunClientOptions,
  type OperationRunResponse,
  type PropertyDeleteOperationRequest,
  type PropertySetOperationRequest,
  type RelocateOperationRequest,
  type RemoveOperationRequest,
  type ResolveOperationRequest,
  type RevertOperationRequest,
  type SwitchOperationRequest,
  type UnlockOperationRequest,
  type UpdateOperationRequest,
  type UpgradeOperationRequest,
} from "./operationRunRpcClient";

export class BackendOperationClient implements OperationClient {
  public constructor(private readonly backendService: Pick<BackendService, "initialize">) {}

  public async add(request: AddOperationRequest, options?: OperationRunClientOptions): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).add(request, options);
  }

  public async cleanup(
    request: CleanupOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).cleanup(request, options);
  }

  public async upgrade(
    request: UpgradeOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).upgrade(request, options);
  }

  public async remove(
    request: RemoveOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).remove(request, options);
  }

  public async move(
    request: MoveOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).move(request, options);
  }

  public async resolve(
    request: ResolveOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).resolve(request, options);
  }

  public async revert(
    request: RevertOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).revert(request, options);
  }

  public async update(
    request: UpdateOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).update(request, options);
  }

  public async branchCreate(
    request: BranchCreateOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).branchCreate(request, options);
  }

  public async switch(
    request: SwitchOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).switch(request, options);
  }

  public async relocate(
    request: RelocateOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).relocate(request, options);
  }

  public async merge(
    request: MergeRangeOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).merge(request, options);
  }

  public async propertySet(
    request: PropertySetOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).propertySet(request, options);
  }

  public async propertyDelete(
    request: PropertyDeleteOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).propertyDelete(request, options);
  }

  public async changelistSet(
    request: ChangelistSetOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).changelistSet(request, options);
  }

  public async changelistClear(
    request: ChangelistClearOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).changelistClear(request, options);
  }

  public async lock(
    request: LockOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).lock(request, options);
  }

  public async unlock(
    request: UnlockOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).unlock(request, options);
  }

  public async commit(
    request: CommitOperationRequest,
    options?: OperationRunClientOptions,
  ): Promise<OperationRunResponse> {
    const connection = await this.backendService.initialize();
    return new OperationRunRpcClient(connection).commit(request, options);
  }
}
